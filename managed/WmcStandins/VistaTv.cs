// Vista's TV recording service (ehrecvr on Windows) is not here. Vista's
// Media Center asks for it wherever TV can come in, after a video has played
// and on recorded TV, and when it cannot be reached because it was never
// installed, it shows "component registration failure". There is nothing to
// tell: this replaces that check's body (redirects.txt, [vista]), and the
// pages carry on as on a PC with no TV.
#if VISTA
using System;
using System.Runtime.InteropServices;

namespace WmcStandins
{
    public static partial class Compat
    {
        // MediaCenter.Video.RecordHelper.HandleComponentRegistrationFailure:
        // true = handled.
        public static bool Vista_RecorderMissing(MediaCenter.Video.RecordHelper helper, Exception e)
        {
            var com = e as COMException;
            return com != null && (com.ErrorCode == unchecked((int)0x80040154)       // class not registered
                                   || com.ErrorCode == unchecked((int)0x80080005));  // server could not start
        }

        // MediaCenter.Video.RecordHelper.LoadRecordingML: it tries to reach
        // the service three times, two seconds apart, on the UI thread (the
        // first time a video page is left, or recorded TV opens). The answer
        // is known: not registered, at once.
        public static Exception Vista_NoRecordingService(MediaCenter.Video.RecordHelper helper)
        {
            return new COMException("The recording service is not installed", unchecked((int)0x80040154));
        }
    }
}
#endif
