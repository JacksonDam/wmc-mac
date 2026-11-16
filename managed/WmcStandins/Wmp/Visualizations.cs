// Visualizations, as Media Center sees them.
//
// When Media Center puts the Player in its "custom" interface mode, the
// Player loads a skin (MCSkin.wmz) whose script hands Media Center a set of
// functions: list the visualization categories, say which is showing, show
// another. Media Center calls them by name through reflection
// (EHMedia.SkinDispatch). These are those functions over the visualizations
// Windows Media Player comes with. Nothing draws them: the Visualize page
// opens, names them and lets you step through them over an empty picture.
using System;
using System.Collections;
using System.Reflection;

namespace WmcStandins.Wmp
{
    public sealed class VisualizationCategory
    {
        readonly string id, name;
        readonly string[] presets;

        public VisualizationCategory(string id, string name, params string[] presets)
        {
            this.id = id;
            this.name = name;
            this.presets = presets;
        }

        public string ID { get { return id; } }
        public string title { get { return name; } }
        internal string[] Presets { get { return presets; } }
    }

    // What GetCurrentVisualization returns.
    public sealed class CurrentVisualization
    {
        readonly VisualizationCategory category;
        readonly int preset;

        internal CurrentVisualization(VisualizationCategory category, int preset)
        {
            this.category = category;
            this.preset = preset;
        }

        public string ID { get { return category.ID; } }
        public string title { get { return category.title; } }
        public string presetTitle { get { return category.Presets[preset]; } }
        public int presetIndex { get { return preset; } }
        public int presetCount { get { return category.Presets.Length; } }
    }

    // A script function: Media Center calls it as the object's default member.
    [DefaultMember("Call")]
    public sealed class SkinFunction
    {
        readonly Func<object[], object> body;

        internal SkinFunction(Func<object[], object> body)
        {
            this.body = body;
        }

        public object Call() { return body(new object[0]); }
        public object Call(object a) { return body(new[] { a }); }
        public object Call(object a, object b) { return body(new[] { a, b }); }
    }

    public sealed class VisualizationSkin
    {
        static readonly VisualizationCategory[] s_categories =
        {
            new VisualizationCategory("Alchemy", "Alchemy", "Random"),
            new VisualizationCategory("Bars and Waves", "Bars and Waves", "Bars", "Ocean Mist", "Fire Storm", "Scope"),
            new VisualizationCategory("Battery", "Battery", "randomization"),
        };

        int current = 1, preset;

        public object EnumerateCategories { get { return new SkinFunction(args => (IEnumerable)s_categories); } }
        public object GetCurrentVisualization { get { return new SkinFunction(args => new CurrentVisualization(s_categories[current], preset)); } }
        public object SetCurrentVisualization { get { return new SkinFunction(args => { Select(args, false); return null; }); } }
        public object SetCurrentVisualizationWithPresetTitle { get { return new SkinFunction(args => { Select(args, true); return null; }); } }

        void Select(object[] args, bool byTitle)
        {
            if (args.Length < 1) return;
            string id = Convert.ToString(args[0]);
            for (int i = 0; i < s_categories.Length; i++)
            {
                if (!string.Equals(s_categories[i].ID, id, StringComparison.OrdinalIgnoreCase)) continue;
                current = i;
                preset = 0;
                string[] presets = s_categories[i].Presets;
                if (args.Length > 1 && byTitle)
                {
                    int p = Array.IndexOf(presets, Convert.ToString(args[1]));
                    if (p >= 0) preset = p;
                }
                else if (args.Length > 1)
                {
                    int p;
                    try { p = Convert.ToInt32(args[1]); } catch (FormatException) { p = 0; } catch (InvalidCastException) { p = 0; }
                    preset = ((p % presets.Length) + presets.Length) % presets.Length;
                }
                return;
            }
        }
    }
}
