// COM classes Media Center creates by class id, and the managed stand-ins
// that take their place.
using System;
using System.Collections.Generic;

namespace WmcStandins
{
    public static class ComClasses
    {
        static readonly Dictionary<Guid, Type> s_classes = new Dictionary<Guid, Type>
        {
            // "English3x4InputModule": text entry with a remote control's number keys.
            { new Guid("C77A3910-BAB0-4A38-A0A1-405FA9257C1B"), typeof(Input.KeypadInputModule) },
        };

        public static Type Find(Guid clsid)
        {
            Type t;
            return s_classes.TryGetValue(clsid, out t) ? t : null;
        }
    }
}
