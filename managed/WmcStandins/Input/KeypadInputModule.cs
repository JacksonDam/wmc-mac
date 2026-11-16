// Text entry with a remote control's number keys ("triple tap"): the stand-in
// for the input module Media Center loads as a COM object for Western
// languages. A key cycles through its letters while it is pressed again
// quickly; Media Center's own timer says when a letter is final. Characters
// typed on a keyboard go straight in.
using System;
using System.Text;
using ehiUserXp;

namespace WmcStandins.Input
{
    public sealed class KeypadInputModule : IMediaCenterInputModule, IMediaCenterInputKeyMap
    {
        // Modes: lower case, upper case, digits. The keys, in Media Center's
        // order: 1 2 3 4 5 6 7 8 9 * 0 #.
        internal static readonly string[][] Letters =
        {
            new[] { ".,?!'\"-()@/:_1", "abc2", "def3", "ghi4", "jkl5", "mno6", "pqrs7", "tuv8", "wxyz9", "*", " 0", "#" },
            new[] { ".,?!'\"-()@/:_1", "ABC2", "DEF3", "GHI4", "JKL5", "MNO6", "PQRS7", "TUV8", "WXYZ9", "*", " 0", "#" },
            new[] { "1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#" },
        };
        internal const string Keys = "123456789*0#";

        public IMediaCenterInputField Activate(IMediaCenterInputCallback callback)
        {
            return new KeypadInputField(callback);
        }

        public IMediaCenterInputKeyMap KeyMap { get { return this; } }
        public bool SupportsCandidateList { get { return false; } }
        public bool SendArrowKeys { get { return false; } }

        public int UIModeCount { get { return Letters.Length; } }

        // The label shown on each key of the on-screen keypad.
        public string[] UIModeKeyMap(int mode)
        {
            string[] labels = new string[Keys.Length];
            for (int i = 0; i < labels.Length; i++)
            {
                string letters = Letters[mode][i];
                if (mode == 2) labels[i] = letters;
                else if (i == 0) labels[i] = ".,?!";
                else if (i == 10) labels[i] = "space";
                else if (letters.Length > 1) labels[i] = letters.Substring(0, letters.Length - 1);
                else labels[i] = "";
            }
            return labels;
        }
    }

    sealed class KeypadInputField : IMediaCenterInputField
    {
        readonly IMediaCenterInputCallback _callback;
        readonly StringBuilder _text = new StringBuilder();
        int _mode;
        int _pendingKey = -1;     // the keypad key whose letter is still cycling
        int _pendingIndex;

        public KeypadInputField(IMediaCenterInputCallback callback)
        {
            _callback = callback;
        }

        public void SetString(string value)
        {
            _text.Length = 0;
            _text.Append(value ?? "");
            _pendingKey = -1;
        }

        public void ProcessInput(ushort input, bool remote)
        {
            char ch = (char)input;
            uint flags = (uint)EHIMECharFlags.EHIMECF_Normal;
            if (ch == '\b')
            {
                if (_text.Length > 0) _text.Length--;
                _pendingKey = -1;
            }
            else
            {
                int key = remote ? KeypadInputModule.Keys.IndexOf(ch) : -1;
                if (key < 0)
                {
                    if (ch < ' ') return;
                    _text.Append(ch);
                    _pendingKey = -1;
                }
                else
                {
                    string letters = KeypadInputModule.Letters[_mode][key];
                    if (key == _pendingKey && _text.Length > 0)
                    {
                        _pendingIndex = (_pendingIndex + 1) % letters.Length;
                        _text[_text.Length - 1] = letters[_pendingIndex];
                    }
                    else
                    {
                        _pendingIndex = 0;
                        _text.Append(letters[0]);
                    }
                    _pendingKey = letters.Length > 1 ? key : -1;
                    if (_pendingKey >= 0) flags = (uint)EHIMECharFlags.EHIMECF_TimedCandidate;
                }
            }
            _callback.UpdateField(_text.ToString(), ref flags);
        }

        public void ProcessSpecialInput(MediaCenterInputSpecialKey input, bool remote)
        {
        }

        public void ProcessCandidateSelection(int selection)
        {
        }

        // Media Center's timer ran out: the letter shown is final.
        public void CandidateTimeout()
        {
            _pendingKey = -1;
        }

        public void SelectNextMode()
        {
            _pendingKey = -1;
            _mode = (_mode + 1) % KeypadInputModule.Letters.Length;
            _callback.SelectKeyMap(_mode);
        }
    }
}
