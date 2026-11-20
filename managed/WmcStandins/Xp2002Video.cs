// XP Media Center Edition 2002's video player. It plays a video file
// through a COM player (ehiPlay.FilePlayerClass, made with `new` in
// VideoViewport) driven through IPlayer and IFilePlayer, which tells it what
// happened through IPlayerEvents. That `new` is patched to
// Compat.Xp2002_NewFilePlayer (redirects.txt), which makes this player
// instead: the same native player as the other Media Centers' stand-ins
// (native/platform/video.m), showing its frames on a surface of the 2002
// engine's (native/duser/duser_video.m). The surface's number is what the
// framework draws the picture from, as the "surface owner" of an inset
// video and the "front buffer" of a full-screen one. Positions are in 10 ms
// units.
#if XP2002
using System;
using System.Runtime.InteropServices;
using System.Threading;
using ehiPlay;
using Timer = System.Threading.Timer;

namespace WmcStandins
{
    public static partial class Compat
    {
        public static object Xp2002_NewFilePlayer()
        {
            return new Playback.Xp2002FilePlayer();
        }

        // The recording service's COM objects: there are none.
        public static object Xp2002_NoRecorder()
        {
            return null;
        }

        // RecordHelper, which video playback asks about recordings, gave up
        // before making its events object (it found no recording service):
        // one is made, which knows of no tuners, so nothing is recording.
        public static void Xp2002_RecorderMissing(MediaCenter.Video.RecordHelper helper, string debugError, Exception e)
        {
            var field = typeof(MediaCenter.Video.RecordHelper).GetField("_recordingEvents",
                System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public);
            if (field != null && field.GetValue(helper) == null) field.SetValue(helper, new MediaCenter.Video.RecordingEvents(null));
            ComTodo.Log("video", "no recording service here" + (debugError != null ? ": " + debugError.Trim() : ""));
        }
    }
}

namespace WmcStandins.Playback
{
    public sealed class Xp2002FilePlayer : WmcPlayBases.FilePlayerBase
    {
        const string Shim = "wmcshim";
        [DllImport(Shim)] static extern IntPtr wmc_video_open(string path);
        [DllImport(Shim)] static extern void wmc_video_close(IntPtr handle);
        [DllImport(Shim)] static extern int wmc_video_state(IntPtr handle);
        [DllImport(Shim)] static extern void wmc_video_size(IntPtr handle, out int width, out int height);
        [DllImport(Shim)] static extern double wmc_video_duration(IntPtr handle);
        [DllImport(Shim)] static extern double wmc_video_position(IntPtr handle);
        [DllImport(Shim)] static extern void wmc_video_seek(IntPtr handle, double seconds);
        [DllImport(Shim)] static extern void wmc_video_play(IntPtr handle);
        [DllImport(Shim)] static extern void wmc_video_pause(IntPtr handle);
        [DllImport(Shim)] static extern void wmc_video_set_rate(IntPtr handle, float rate);
        [DllImport(Shim)] static extern void wmc_video_set_surface(IntPtr handle, int surfaceId);
        [DllImport(Shim)] static extern int du_video_surface_new();
        [DllImport(Shim)] static extern void du_video_surface_free(int surface);
        [DllImport(Shim)] static extern void wmc_log_line(string channel, string text);

        IntPtr _video;
        int _surface;
        IPlayerEvents _events;
        PlayerState _state = PlayerState.state_Uninitialized;
        float _rate = 1;
        Timer _timer;
        bool _endOfMedia, _surfaceCopy;

        static void Log(string text) { wmc_log_line("video", "2002 player: " + text); }

        void SetState(PlayerState state)
        {
            if (state == _state) return;
            var previous = _state;
            _state = state;
            if (_events != null) _events.StateChange(previous, state);
        }

        public override void Initialize(uint window, uint renderDevice, IPlayerEvents events)
        {
            _events = events;
            if (_surface == 0) _surface = du_video_surface_new();
            Log("initialised, surface " + _surface);
            SetState(PlayerState.state_Initialized);
        }

        public override void Uninitialize()
        {
            CloseVideo();
            if (_surface != 0) du_video_surface_free(_surface);
            _surface = 0;
            _events = null;
            _state = PlayerState.state_Uninitialized;
        }

        // COM's OpenFileMedia returns once the file is open (or fails): wait
        // for the native player to know, as it opens in the background.
        public override void OpenFileMedia(string file)
        {
            CloseVideo();
            string path = Compat.FixPath(file);
            _video = wmc_video_open(path);
            int state = 0;
            for (int waited = 0; _video != IntPtr.Zero && waited < 10000; waited += 10)
            {
                state = wmc_video_state(_video);
                if (state != 0) break;
                Thread.Sleep(10);
            }
            if (_video == IntPtr.Zero || state == 0 || state == 4)
            {
                Log("cannot play " + path);
                CloseVideo();
                throw new COMException("The file cannot be played", unchecked((int)0xC00D11B1));
            }
            _endOfMedia = false;
            wmc_video_set_surface(_video, _surface);
            int w, h;
            wmc_video_size(_video, out w, out h);
            Log(string.Format("opened {0}: {1}x{2}, {3:0.0} s", System.IO.Path.GetFileName(path), w, h, wmc_video_duration(_video)));
            SetState(PlayerState.state_MediaOpen);
            SetState(PlayerState.state_Stop);
        }

        void CloseVideo()
        {
            if (_timer != null) _timer.Change(Timeout.Infinite, Timeout.Infinite);
            if (_video != IntPtr.Zero) wmc_video_close(_video);
            _video = IntPtr.Zero;
        }

        public override void CloseMedia()
        {
            CloseVideo();
            if (_state != PlayerState.state_Uninitialized) SetState(PlayerState.state_Initialized);
        }

        public override void Play()
        {
            if (_video == IntPtr.Zero) return;
            if (_endOfMedia) { wmc_video_seek(_video, 0); _endOfMedia = false; }
            wmc_video_set_rate(_video, _rate);
            wmc_video_play(_video);
            Watch();
            SetState(PlayerState.state_Play);
        }

        public override void Pause()
        {
            if (_video == IntPtr.Zero) return;
            wmc_video_pause(_video);
            SetState(PlayerState.state_Pause);
        }

        public override void Stop()
        {
            if (_video == IntPtr.Zero) return;
            wmc_video_pause(_video);
            wmc_video_seek(_video, 0);
            SetState(PlayerState.state_Stop);
        }

        // The end of the file is watched for on a pool thread and reported on
        // the UI thread; at the end the player stops, as Windows Media
        // Player's did.
        void Watch()
        {
            if (_timer == null) _timer = new Timer(delegate { Tick(); }, null, Timeout.Infinite, Timeout.Infinite);
            _timer.Change(100, 100);
        }

        void Tick()
        {
            IntPtr video = _video;
            if (video == IntPtr.Zero || _endOfMedia) return;
            if (wmc_video_state(video) != 3) return;
            _endOfMedia = true;
            Log("end of media");
            eHome.ComponentModel.Application.DeferredInvoke(delegate
            {
                if (_events == null || _video != video) return;
                _events.EndOfMedia(null);
                if (_video == video) SetState(PlayerState.state_Stop);
            });
        }

        public override long GetPosition() { return _video == IntPtr.Zero ? 0 : (long)(wmc_video_position(_video) * 100); }
        public override long GetDuration() { return _video == IntPtr.Zero ? 0 : (long)(wmc_video_duration(_video) * 100); }
        public override long GetMaxSeekPosition() { return GetDuration(); }

        public override void SeekToAbsPosition(long l10ms)
        {
            if (_video == IntPtr.Zero) return;
            double length = wmc_video_duration(_video);
            double seconds = Math.Max(0, Math.Min(l10ms / 100.0, length));
            if (seconds < length - 0.05) _endOfMedia = false;
            wmc_video_seek(_video, seconds);
        }

        public override void SeekToRelPosition(long l10ms)
        {
            SeekToAbsPosition(GetPosition() + l10ms);
        }

        public override void SetPlayRate(float rate)
        {
            _rate = rate;
            if (_video != IntPtr.Zero && _state == PlayerState.state_Play) wmc_video_set_rate(_video, rate);
            if (_events != null) _events.RateChange();
        }

        public override float GetPlayRate() { return _rate; }
        public override PlayerState GetState() { return _state; }

        public override void GetNativeContentSize(out uint width, out uint height)
        {
            int w = 0, h = 0;
            if (_video != IntPtr.Zero) wmc_video_size(_video, out w, out h);
            width = (uint)w;
            height = (uint)h;
        }

        // All of each frame is picture.
        public override void GetVideoSourceRect(out int x, out int y, out int width, out int height)
        {
            int w = 0, h = 0;
            if (_video != IntPtr.Zero) wmc_video_size(_video, out w, out h);
            x = y = 0;
            width = w;
            height = h;
        }

        public override uint HACK_GetSurfaceOwner() { return (uint)_surface; }
        public override IntPtr HACK_GetFrontBuffer() { return (IntPtr)_surface; }
        public override object GetSurfaceOwner() { return null; }
        public override object GetFrontBuffer() { return null; }
        public override bool GetEnableSurfaceCopy() { return _surfaceCopy; }
        public override void SetEnableSurfaceCopy(bool copy) { _surfaceCopy = copy; }
        public override void SetActive(bool active) { }
        public override void ResetOnStop(bool reset) { }
        public override void OnLostDevice(bool lost) { }
    }
}
#endif
