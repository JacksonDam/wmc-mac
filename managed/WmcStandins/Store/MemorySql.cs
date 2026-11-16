// The few SQL statements the object store sends as text, for the in-memory
// database (MemoryDatabase.cs):
//
//   select * from <table> where <condition>
//   delete from <table> where <condition>
//   drop table <table>
//
// A condition is made of `<column> <op> <literal>` (=, <>, <, <=, >, >=),
// `<column> is [not] null`, `<column> in (<literal>, ...)`,
// `<column> between <literal> and <literal>`, joined with and / or / not and
// grouped with parentheses. Literals are numbers, 'quoted strings', null,
// true and false; anything else is kept as its text. Anything else is
// reported on the "todo" log channel and does nothing.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace WmcStandins.Store
{
    sealed class MemCondition
    {
        // Is the condition true of this row of this table?
        public Func<MemTable, MemRow, bool> Test;
    }

    static class MemSql
    {
        sealed class Lexer
        {
            readonly List<string> tokens = new List<string>();
            int at;

            public Lexer(string text)
            {
                int i = 0;
                while (i < text.Length)
                {
                    char c = text[i];
                    if (char.IsWhiteSpace(c)) { i++; continue; }
                    if (c == '\'')
                    {
                        var sb = new StringBuilder("'");
                        i++;
                        while (i < text.Length)
                        {
                            if (text[i] == '\'')
                            {
                                if (i + 1 < text.Length && text[i + 1] == '\'') { sb.Append('\''); i += 2; continue; }
                                i++;
                                break;
                            }
                            sb.Append(text[i++]);
                        }
                        tokens.Add(sb.ToString());
                        continue;
                    }
                    if ("(),".IndexOf(c) >= 0) { tokens.Add(c.ToString()); i++; continue; }
                    if ("<>=!".IndexOf(c) >= 0)
                    {
                        int start = i;
                        while (i < text.Length && "<>=!".IndexOf(text[i]) >= 0) i++;
                        tokens.Add(text.Substring(start, i - start));
                        continue;
                    }
                    int s = i;
                    while (i < text.Length && !char.IsWhiteSpace(text[i]) && "(),'<>=!".IndexOf(text[i]) < 0) i++;
                    tokens.Add(text.Substring(s, i - s));
                }
            }

            public string Peek { get { return at < tokens.Count ? tokens[at] : null; } }
            public bool AtEnd { get { return at >= tokens.Count; } }
            public string Next() { return at < tokens.Count ? tokens[at++] : null; }

            public bool Take(string word)
            {
                if (Peek != null && string.Equals(Peek, word, StringComparison.OrdinalIgnoreCase)) { at++; return true; }
                return false;
            }

            public void Expect(string word)
            {
                if (!Take(word)) throw new FormatException("expected '" + word + "' at '" + Peek + "'");
            }
        }

        // ---- statements ----------------------------------------------------------------

        // "select * from T where C": the table's name and the condition.
        public static bool ParseSelect(string sql, out string table, out MemCondition condition)
        {
            table = null;
            condition = null;
            try
            {
                var lx = new Lexer(sql);
                lx.Expect("select");
                lx.Expect("*");
                lx.Expect("from");
                table = lx.Next();
                condition = lx.Take("where") ? Condition(lx) : Always();
                return lx.AtEnd;
            }
            catch (FormatException e)
            {
                ComTodo.Log("todo", "store: cannot read query \"" + sql + "\": " + e.Message);
                return false;
            }
        }

        // Runs a statement that changes the database. Returns the number of rows removed.
        public static int Execute(MemDatabase db, string sql)
        {
            try
            {
                var lx = new Lexer(sql);
                if (lx.Take("drop"))
                {
                    lx.Expect("table");
                    db.Drop(lx.Next());
                    return 0;
                }
                if (lx.Take("delete"))
                {
                    lx.Expect("from");
                    MemTable table = db.Table(lx.Next());
                    MemCondition condition = lx.Take("where") ? Condition(lx) : Always();
                    if (!lx.AtEnd) throw new FormatException("text after the condition");
                    if (table == null) return 0;
                    int removed = 0;
                    foreach (MemRow row in table.Rows.ToArray())
                    {
                        if (condition.Test(table, row)) { table.Delete(row); removed++; }
                    }
                    return removed;
                }
                throw new FormatException("not a statement this database knows");
            }
            catch (FormatException e)
            {
                ComTodo.Log("todo", "store: cannot run \"" + sql + "\": " + e.Message);
                return 0;
            }
        }

        // ---- conditions ----------------------------------------------------------------

        static MemCondition Always()
        {
            return new MemCondition { Test = (t, r) => true };
        }

        static MemCondition Condition(Lexer lx)
        {
            MemCondition left = Conjunction(lx);
            while (lx.Take("or"))
            {
                MemCondition a = left, b = Conjunction(lx);
                left = new MemCondition { Test = (t, r) => a.Test(t, r) || b.Test(t, r) };
            }
            return left;
        }

        static MemCondition Conjunction(Lexer lx)
        {
            MemCondition left = Unary(lx);
            while (lx.Take("and"))
            {
                MemCondition a = left, b = Unary(lx);
                left = new MemCondition { Test = (t, r) => a.Test(t, r) && b.Test(t, r) };
            }
            return left;
        }

        static MemCondition Unary(Lexer lx)
        {
            if (lx.Take("not"))
            {
                MemCondition inner = Unary(lx);
                return new MemCondition { Test = (t, r) => !inner.Test(t, r) };
            }
            if (lx.Take("("))
            {
                MemCondition inner = Condition(lx);
                lx.Expect(")");
                return inner;
            }
            return Comparison(lx);
        }

        static MemCondition Comparison(Lexer lx)
        {
            string column = lx.Next();
            if (column == null) throw new FormatException("expected a column name");
            if (lx.Take("is"))
            {
                bool not = lx.Take("not");
                lx.Expect("null");
                // ("x is null null" is what the store writes for "is null" with no value)
                if (string.Equals(lx.Peek, "null", StringComparison.OrdinalIgnoreCase)) lx.Next();
                return new MemCondition { Test = (t, r) => (Value(t, r, column) == null) != not };
            }
            if (lx.Take("in"))
            {
                lx.Expect("(");
                var items = new List<object>();
                if (!lx.Take(")"))
                {
                    do items.Add(Literal(lx.Next())); while (lx.Take(","));
                    lx.Expect(")");
                }
                return new MemCondition { Test = (t, r) => { object v = Value(t, r, column); foreach (object item in items) if (Compare(v, item) == 0) return true; return false; } };
            }
            if (lx.Take("between"))
            {
                object low = Literal(lx.Next());
                lx.Expect("and");
                object high = Literal(lx.Next());
                return new MemCondition { Test = (t, r) => { object v = Value(t, r, column); return v != null && Compare(v, low) >= 0 && Compare(v, high) <= 0; } };
            }
            string op = lx.Next();
            object literal = Literal(lx.Next());
            Func<int, bool> holds;
            switch (op)
            {
                case "=": holds = c => c == 0; break;
                case "<>":
                case "!=": holds = c => c != 0; break;
                case "<": holds = c => c < 0; break;
                case "<=": holds = c => c <= 0; break;
                case ">": holds = c => c > 0; break;
                case ">=": holds = c => c >= 0; break;
                default: throw new FormatException("unknown comparison '" + op + "'");
            }
            return new MemCondition
            {
                Test = (t, r) =>
                {
                    object v = Value(t, r, column);
                    if (v == null || literal == null) return false;   // as SQL: a comparison with null is never true
                    return holds(Compare(v, literal));
                }
            };
        }

        static object Literal(string token)
        {
            if (token == null) throw new FormatException("expected a value");
            if (token.StartsWith("'", StringComparison.Ordinal)) return token.Substring(1);
            if (string.Equals(token, "null", StringComparison.OrdinalIgnoreCase)) return null;
            if (string.Equals(token, "true", StringComparison.OrdinalIgnoreCase)) return true;
            if (string.Equals(token, "false", StringComparison.OrdinalIgnoreCase)) return false;
            long l;
            if (long.TryParse(token, NumberStyles.Integer, CultureInfo.InvariantCulture, out l)) return l;
            double d;
            if (double.TryParse(token, NumberStyles.Float, CultureInfo.InvariantCulture, out d)) return d;
            return token;
        }

        static object Value(MemTable table, MemRow row, string column)
        {
            int c = table.Column(column);
            if (c < 0) return null;
            return MemValue.ToObject(table.Columns[c].Type, table.Get(row, c));
        }

        static int Compare(object value, object literal)
        {
            if (value == null) return literal == null ? 0 : -1;
            if (literal == null) return 1;
            if (value is string)
                return string.Compare((string)value, Convert.ToString(literal, CultureInfo.InvariantCulture), StringComparison.OrdinalIgnoreCase);
            if (value is bool)
            {
                bool b = literal is bool ? (bool)literal : (literal is long ? (long)literal != 0 : false);
                return ((bool)value).CompareTo(b);
            }
            if (value is Guid)
            {
                Guid g;
                return Guid.TryParse(Convert.ToString(literal, CultureInfo.InvariantCulture), out g) ? ((Guid)value).CompareTo(g) : 1;
            }
            if (value is long && literal is long) return ((long)value).CompareTo((long)literal);
            if ((value is long || value is double) && (literal is long || literal is double))
                return Convert.ToDouble(value, CultureInfo.InvariantCulture).CompareTo(Convert.ToDouble(literal, CultureInfo.InvariantCulture));
            return string.Compare(Convert.ToString(value, CultureInfo.InvariantCulture), Convert.ToString(literal, CultureInfo.InvariantCulture), StringComparison.OrdinalIgnoreCase);
        }
    }
}
