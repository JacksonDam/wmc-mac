// Vista's video player. Vista's Media Center plays a video file through a
// COM player (ehiPlay.WmpOcxPlayerClass, made with `new` in VideoViewport)
// that it drives through IPlayer, IFilePlayer and IWmpOcxPlayer, and that
// tells it what happened through IPlayerEvents. That `new` is patched to
// Compat.Vista_NewFilePlayer, which makes this player instead: it plays
// through the same native player as Windows 7's stand-in (MacPlayer), into
// the dynamic surface Media Center made for the video (its id comes with
// Initialize). Positions are in 10 ms units.
#if VISTA
using System;
using System.Runtime.InteropServices;
using System.Threading;
using ehiPlay;
using Timer = System.Threading.Timer;

namespace WmcStandins
{
    public static partial class Compat
    {
        public static object Vista_NewFilePlayer()
        {
            return new Playback.VistaFilePlayer();
        }
    }
}

namespace WmcStandins.Playback
{
    public sealed class VistaFilePlayer : WmcPlayBases.FilePlayerBase
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
        [DllImport(Shim)] static extern void wmc_log_line(string channel, string text);

        IntPtr _video;
        int _surface;
        IPlayerEvents _events;
        PlayerState _state = PlayerState.state_Uninitialized;
        float _rate = 1;
        string _title = "";
        Timer _timer;
        bool _endOfMedia;

        static void Log(string text) { wmc_log_line("video", "Vista player: " + text); }

        void SetState(PlayerState state)
        {
            if (state == _state) return;
            var previous = _state;
            _state = state;
            if (_events != null) _events.StateChange(previous, state);
        }

        public override void Initialize(IntPtr hwnd, int surface, IPlayerEvents events, VideoRenderer renderer)
        {
            _surface = surface;
            _events = events;
            Log("initialised, surface " + surface + ", renderer " + renderer);
            SetState(PlayerState.state_Initialized);
        }

        public override void Uninitialize()
        {
            CloseVideo();
            _events = null;
            _state = PlayerState.state_Uninitialized;
        }

        public override void OpenFileMedia(string file, IWMReaderCallback registration) { Open(file); }
        public override void OpenWmpOcxMedia(string file, IWMReaderCallback registration) { Open(file); }

        // COM's OpenFileMedia returns once the file is open (or fails): wait
        // for the native player to know, as it opens in the background.
        void Open(string file)
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
            _title = System.IO.Path.GetFileNameWithoutExtension(path);
            _endOfMedia = false;
            wmc_video_set_surface(_video, _surface);
            int w, h;
            wmc_video_size(_video, out w, out h);
            Log(string.Format("opened {0}: {1}x{2}, {3:0.0} s", _title, w, h, wmc_video_duration(_video)));
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

        // The end of the file is watched for on a pool thread (Media Center
        // drives the player from a thread with no message loop, where a UI
        // timer never fires) and reported on the UI thread, where Media Center
        // expects EndOfMedia (it acts on it at once).
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
            Microsoft.MediaCenter.UI.Application.DeferredInvoke(delegate
            {
                if (_events != null && _video == video) _events.EndOfMedia(null);
            });
        }

        public override long GetPosition() { return _video == IntPtr.Zero ? 0 : (long)(wmc_video_position(_video) * 100); }
        public override long GetDuration() { return _video == IntPtr.Zero ? 0 : (long)(wmc_video_duration(_video) * 100); }
        public override long GetMinSeekPosition() { return 0; }
        public override long GetMaxSeekPosition() { return GetDuration(); }

        public override void SeekToAbsPosition(long l10ms)
        {
            if (_video == IntPtr.Zero) return;
            double length = wmc_video_duration(_video);
            double seconds = Math.Max(0, Math.Min(l10ms / 100.0, length));
            // (At the end Media Center seeks to the end: that is no new start,
            // or the end would be reported again and again.)
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
        public override bool GetReadyState() { return _video != IntPtr.Zero; }
        public override bool GetDownresState() { return false; }

        public override void GetNativeContentSize(out uint width, out uint height)
        {
            int w = 0, h = 0;
            if (_video != IntPtr.Zero) wmc_video_size(_video, out w, out h);
            width = (uint)w;
            height = (uint)h;
        }

        public override void SetActive(bool active) { }
        public override void ResetOnStop(bool reset) { }
        public override void IsPlayList(ref bool playlist) { playlist = false; }
        public override void ItemTitle(ref string title) { title = _title; }
        public override void PlaylistTitle(ref string title) { title = _title; }
    }
}
#endif
