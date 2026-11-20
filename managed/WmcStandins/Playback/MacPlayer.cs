// The player for video files: the stand-in for the native player Media
// Center loads for them (through mcplayerinterop.dll, which cannot run here).
//
// Media Center's playback session drives a player through a few interfaces
// declared in ehshell.dll. This class implements them over an AVPlayer
// (native/splash/sp_video.m), which presents its frames into the render
// engine's video surface. The session expects the steps
//   Initialize -> (Closed) -> Open -> (Open) -> Build -> (Built) -> Play
// each to be announced through StatusChanged after the call has returned,
// so every change of state is raised as a separate piece of queued work.
// Windows 7 only (not Vista or XP): Vista's Media Center has no Microsoft.MediaCenter.Playback.
#if !VISTA && !XP

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using Microsoft.MediaCenter.Playback;
using Microsoft.MediaCenter.UI;
using Timer = Microsoft.MediaCenter.UI.Timer;

namespace WmcStandins.Playback
{
    public sealed class MacPlayer : IPlayer, IPlayerActivation, IPlayerSetUri, IShellNotification, IStreamSelector, ITransport, IDisposable
    {
        const string Shim = "wmcshim";
        [DllImport(Shim)] static extern IntPtr wmc_video_open(string path);
        [DllImport(Shim)] static extern void wmc_video_close(IntPtr handle);
        [DllImport(Shim)] static extern int wmc_video_state(IntPtr handle);
        [DllImport(Shim)] static extern void wmc_video_size(IntPtr handle, out int width, out int height);
        [DllImport(Shim)] static extern int wmc_video_has_sound(IntPtr handle);
        [DllImport(Shim)] static extern double wmc_video_duration(IntPtr handle);
        [DllImport(Shim)] static extern double wmc_video_position(IntPtr handle);
        [DllImport(Shim)] static extern void wmc_video_seek(IntPtr handle, double seconds);
        [DllImport(Shim)] static extern void wmc_video_play(IntPtr handle);
        [DllImport(Shim)] static extern void wmc_video_pause(IntPtr handle);
        [DllImport(Shim)] static extern void wmc_video_set_rate(IntPtr handle, float rate);
        [DllImport(Shim)] static extern void wmc_video_set_volume(IntPtr handle, float volume, int muted);
        [DllImport(Shim)] static extern void wmc_video_set_surface(IntPtr handle, int surfaceId);

        sealed class Stream : StreamDescriptor
        {
            readonly ulong _id;
            readonly StreamType _type;
            readonly Dictionary<string, object> _properties = new Dictionary<string, object> { { "Default", true }, { "Selectable", true } };
            public Stream(ulong id, StreamType type) { _id = id; _type = type; }
            public override ulong Id { get { return _id; } }
            public override StreamType Type { get { return _type; } }
            public override IDictionary<string, object> Properties { get { return _properties; } }
        }

        sealed class Video : IVideoPresentation
        {
            readonly MacPlayer _player;
            int _surfaceId;
            public Video(MacPlayer player) { _player = player; }
            public SizeF AspectRatio
            {
                get
                {
                    int w, h;
                    wmc_video_size(_player._video, out w, out h);
                    return w > 0 && h > 0 ? new SizeF(w, h) : new SizeF(16, 9);
                }
            }
            public int SurfaceId
            {
                get { return _surfaceId; }
                set
                {
                    _surfaceId = value;
                    if (_player._video != IntPtr.Zero) wmc_video_set_surface(_player._video, value);
                }
            }
            public IntPtr WindowHandle { get; set; }
            public event EventHandler AspectRatioChanged { add { } remove { } }
            public void SetFreeze(bool value) { }
        }

        sealed class Audio : IAudioPresentation
        {
            readonly MacPlayer _player;
            float _volume = 1;
            bool _muted;
            public Audio(MacPlayer player) { _player = player; }
            void Apply()
            {
                if (_player._video != IntPtr.Zero) wmc_video_set_volume(_player._video, _volume, _muted ? 1 : 0);
                if (StatusChanged != null) StatusChanged(this, EventArgs.Empty);
            }
            public float Volume { get { return _volume; } set { _volume = Math.Max(0, Math.Min(1, value)); Apply(); } }
            public bool IsMuted { get { return _muted; } set { _muted = value; Apply(); } }
            public event EventHandler StatusChanged;
        }

        IntPtr _video;
        PlayerState _state = PlayerState.Uninitialized;
        TransportState _transport = TransportState.Invalid;
        float _rate = 1;
        bool _endOfMedia;
        readonly List<StreamDescriptor> _streams = new List<StreamDescriptor>();     // all there are
        readonly List<StreamDescriptor> _selected = new List<StreamDescriptor>();    // those being played
        readonly List<ulong> _toSelect = new List<ulong>(), _toDeselect = new List<ulong>();
        readonly Dictionary<string, object> _properties = new Dictionary<string, object>();
        readonly Video _videoPresentation;
        readonly Audio _audioPresentation;
        Timer _timer;
        Announcement _denial;
        long _lastPosition = -1;

        public MacPlayer()
        {
            _videoPresentation = new Video(this);
            _audioPresentation = new Audio(this);
            PositionEventInterval = TimeSpan.FromMilliseconds(250);
        }

        static void Log(string text) { ComTodo.Log("video", text); }

        // ---- IServiceProvider: the interfaces this player offers -------------------------

        public object GetService(Type type)
        {
            return type != null && type.IsInstanceOfType(this) ? this : null;
        }

        // ---- IPlayer -------------------------------------------------------------------

        public IntPtr SoftwareQualityMetricsHandle { get; set; }
        public PlayerState State { get { return _state; } }
        public long Duration { get { return Ticks(_video != IntPtr.Zero ? wmc_video_duration(_video) : 0); } }
        public bool IsReady { get { return _state == PlayerState.Open || _state == PlayerState.Built; } }
        public float Buffering { get { return 1; } }
        public Announcement FirstDenial { get { return _denial; } }
        // The streams being played: the picture from the start, the sound once
        // the session has selected it (which it does as soon as it sees it).
        public List<StreamDescriptor> Streams { get { return new List<StreamDescriptor>(_selected); } }
        public AlertHandler AlertHandler { get; set; }
        public IDictionary<string, object> Properties { get { return _properties; } }

        public event EventHandler StatusChanged;
        public event PlayerStreamChangeEventHandler StreamAdded;
        public event PlayerStreamChangeEventHandler StreamRemoved;
        public event PlayerPropertyChangedEventHandler PropertyChanged { add { } remove { } }
        public event PlayerLicenseChangeEventHandler LicenseChangeOccurred { add { } remove { } }

        static long Ticks(double seconds) { return (long)(seconds * TimeSpan.TicksPerSecond); }

        // A change of state, announced once the present call has returned.
        void Enter(PlayerState state)
        {
            Application.DeferredInvoke(delegate
            {
                _state = state;
                Log("player state " + state);
                if (StatusChanged != null) StatusChanged(this, EventArgs.Empty);
            });
        }

        void SetTransport(TransportState state)
        {
            if (_transport == state) return;
            _transport = state;
            Application.DeferredInvoke(delegate { if (TransportStatusChanged != null) TransportStatusChanged(this, EventArgs.Empty); });
        }

        public void Initialize(InitializationOptions options)
        {
            Enter(PlayerState.Closed);
        }

        public void Uninitialize()
        {
            CloseVideo();
            Enter(PlayerState.Uninitialized);
        }

        public void Open(Uri uri)
        {
            CloseVideo();
            _denial = null;
            _endOfMedia = false;
            string path = uri != null && uri.IsFile ? uri.LocalPath : null;
            Log("open " + (path ?? (uri != null ? uri.ToString() : "(nothing)")));
            _video = path != null ? wmc_video_open(path) : IntPtr.Zero;
            if (_video == IntPtr.Zero)
            {
                Fail();
                return;
            }
            if (_videoPresentation.SurfaceId != 0) wmc_video_set_surface(_video, _videoPresentation.SurfaceId);
            Watch();
        }

        // The file cannot be played: say so the way a player does, by a
        // "denial" the session shows as its own error.
        void Fail()
        {
            CloseVideo();
            _denial = new HResultAnnouncement("PlayerError", 0, unchecked((int)0xC00D11B1), "MacPlayer", 0);   // "cannot play the file"
            Application.DeferredInvoke(delegate { if (StatusChanged != null) StatusChanged(this, EventArgs.Empty); });
        }

        void Watch()
        {
            if (_timer == null)
            {
                _timer = new Timer();
                _timer.Interval = 100;
                _timer.AutoRepeat = true;
                _timer.Tick += delegate { Tick(); };
            }
            _timer.Start();
        }

        void Tick()
        {
            if (_video == IntPtr.Zero)
            {
                _timer.Stop();
                return;
            }
            int state = wmc_video_state(_video);
            if (_state == PlayerState.Closed)
            {
                // Still opening.
                if (state == 4) { Fail(); return; }
                if (state == 0) return;
                int w, h;
                wmc_video_size(_video, out w, out h);
                _streams.Clear();
                _selected.Clear();
                if (w > 0 && h > 0)
                {
                    _streams.Add(new Stream(1, StreamType.Video));
                    _selected.Add(_streams[0]);
                }
                if (wmc_video_has_sound(_video) != 0) _streams.Add(new Stream(2, StreamType.Audio));
                Log(string.Format("opened: {0}x{1}, {2} streams, {3:0.0} s", w, h, _streams.Count, wmc_video_duration(_video)));
                // (The streams are simply there when the session looks, on
                // hearing "Open". Announcing each one first makes it choose
                // the sound before it is ready to be told the result.)
                _state = PlayerState.Open;
                if (StatusChanged != null) StatusChanged(this, EventArgs.Empty);
                return;
            }
            if (_state != PlayerState.Built) return;
            if (state == 3 && !_endOfMedia)
            {
                _endOfMedia = true;
                Log("end of media");
                if (TransportStatusChanged != null) TransportStatusChanged(this, EventArgs.Empty);
            }
            long position = Position;
            if (position != _lastPosition)
            {
                _lastPosition = position;
                if (TransportPositionChanged != null) TransportPositionChanged(this, EventArgs.Empty);
            }
        }

        public void Build()
        {
            // The transport comes to life first: the session starts playing
            // the moment it hears "Built", and only through a transport it
            // has already been told is usable.
            Application.DeferredInvoke(delegate
            {
                _transport = TransportState.Stopped;
                if (TransportStatusChanged != null) TransportStatusChanged(this, EventArgs.Empty);
                if (TransportPositionChanged != null) TransportPositionChanged(this, EventArgs.Empty);
            });
            Enter(PlayerState.Built);
        }

        public void Close()
        {
            CloseVideo();
            _transport = TransportState.Invalid;
            Enter(PlayerState.Closed);
        }

        void CloseVideo()
        {
            if (_video != IntPtr.Zero)
            {
                wmc_video_close(_video);
                _video = IntPtr.Zero;
            }
            foreach (var s in _selected.ToArray())
                if (StreamRemoved != null) StreamRemoved(this, new PlayerStreamChangeEventArgs(s));
            _selected.Clear();
            _streams.Clear();
            _toSelect.Clear();
            _toDeselect.Clear();
            if (_timer != null) _timer.Stop();
        }

        public object GetStreamService(ulong streamId, StreamType streamType, Type serviceType)
        {
            if (serviceType == typeof(IVideoPresentation)) return _videoPresentation;
            if (serviceType == typeof(IAudioPresentation)) return _audioPresentation;
            return null;
        }

        public void ResetFirstDenial() { _denial = null; }

        // ---- IPlayerActivation, IPlayerSetUri, IShellNotification -------------------------

        public void SetActive(bool active) { }
        public event EventHandler UriSet;
        public void SetUri(Uri uri)
        {
            if (UriSet != null) UriSet(this, EventArgs.Empty);
        }
        public void WindowStateChanged(WindowState state) { }

        // ---- IStreamSelector: every stream there is, is played ----------------------------

        public List<StreamDescriptor> AvailableStreams { get { return new List<StreamDescriptor>(_streams); } }
        public event PlayerStreamChangeEventHandler AvailableStreamAdded { add { } remove { } }
        public event PlayerStreamChangeEventHandler AvailableStreamRemoved { add { } remove { } }
        public event EventHandler StreamSelectionCommitted;
        public void SelectStream(ulong streamId) { _toSelect.Add(streamId); }
        public void DeselectStream(ulong streamId) { _toDeselect.Add(streamId); }
        public void CommitStreamSelection()
        {
            var select = _toSelect.ToArray();
            var deselect = _toDeselect.ToArray();
            _toSelect.Clear();
            _toDeselect.Clear();
            Application.DeferredInvoke(delegate
            {
                foreach (ulong id in deselect)
                {
                    var s = _selected.Find(x => x.Id == id);
                    if (s == null) continue;
                    _selected.Remove(s);
                    if (StreamRemoved != null) StreamRemoved(this, new PlayerStreamChangeEventArgs(s));
                }
                foreach (ulong id in select)
                {
                    var s = _streams.Find(x => x.Id == id);
                    if (s == null || _selected.Contains(s)) continue;
                    _selected.Add(s);
                    if (StreamAdded != null) StreamAdded(this, new PlayerStreamChangeEventArgs(s));
                }
                if (StreamSelectionCommitted != null) StreamSelectionCommitted(this, EventArgs.Empty);
            });
        }

        // ---- ITransport --------------------------------------------------------------------

        public TransportState TransportState { get { return _transport; } }
        public float Rate
        {
            get { return _rate; }
            set
            {
                // Forwards only: the Mac's player cannot run this file backwards.
                float rate = value > 0 ? value : 1;
                if (rate == _rate) return;
                _rate = rate;
                if (_video != IntPtr.Zero) wmc_video_set_rate(_video, rate);
                Application.DeferredInvoke(delegate { if (TransportStatusChanged != null) TransportStatusChanged(this, EventArgs.Empty); });
            }
        }
        public bool EndOfMedia { get { return _endOfMedia; } }
        public long Position { get { return _video != IntPtr.Zero ? Ticks(wmc_video_position(_video)) : 0; } }
        public long MinSeekPosition { get { return 0; } }
        public long MaxSeekPosition { get { return Duration; } }
        public bool ResetOnStop { get; set; }
        public TimeSpan PositionEventInterval { get; set; }
        public event EventHandler TransportStatusChanged;
        public event EventHandler TransportPositionChanged;

        public void Play()
        {
            if (_video == IntPtr.Zero) return;
            _endOfMedia = false;
            Log("play");
            wmc_video_set_rate(_video, _rate);
            wmc_video_play(_video);
            SetTransport(TransportState.Playing);
            Watch();
        }

        public void Pause()
        {
            if (_video == IntPtr.Zero) return;
            Log("pause");
            wmc_video_pause(_video);
            SetTransport(TransportState.Paused);
        }

        public void Stop()
        {
            if (_video == IntPtr.Zero) return;
            Log("stop");
            wmc_video_pause(_video);
            if (ResetOnStop) wmc_video_seek(_video, 0);
            SetTransport(TransportState.Stopped);
        }

        public void SeekToAbsolutePosition(long position)
        {
            if (_video == IntPtr.Zero) return;
            _endOfMedia = false;
            Log("seek to " + TimeSpan.FromTicks(position));
            wmc_video_seek(_video, Math.Max(0, Math.Min(position, Duration)) / (double)TimeSpan.TicksPerSecond);
        }

        public void SeekToRelativePosition(long offset)
        {
            SeekToAbsolutePosition(Position + offset);
        }

        public void SeekToRelativeFrame(long frames)
        {
            SeekToAbsolutePosition(Position + frames * TimeSpan.TicksPerSecond / 30);
        }

        public void Dispose()
        {
            CloseVideo();
        }
    }
}

#endif
