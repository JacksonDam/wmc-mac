// The stand-in for the Windows Media Player object Media Center hosts: the
// library (MediaLibrary.cs, Collections.cs), the "now playing" playlist and
// the transport. Sound is played by the Mac (native/platform/media.m).
//
// Everything here runs on Media Center's application thread: Media Center
// calls in from it, and the timer that watches for the end of a song is one
// of the framework's own.
using System;
using System.Collections.Generic;
using WmcComBases;
using ehiwmp;
#if XP
using Timer = eHome.UI.Timer;
#else
using Timer = Microsoft.MediaCenter.UI.Timer;
#endif

namespace WmcStandins.Wmp
{
    public sealed class Player : PlayerBase
    {
        public static readonly Guid ClassId = new Guid("6BF52A52-394A-11d3-B153-00C04F79FAA6");
        static Player s_instance;
        public static Player Instance { get { return s_instance ?? (s_instance = new Player()); } }

        readonly MediaCollection _collection = new MediaCollection();
#if !XP
        readonly Library _library;
#endif
        readonly Controls _controls;
        internal readonly Settings Settings;
        readonly Network _network = new Network();
        readonly CdromCollection _cdroms = new CdromCollection();
        readonly PlaylistCollection _playlists;
        readonly Random _random = new Random();
        readonly PlayerApplication _application = new PlayerApplication();

        Playlist _playlist;
        MediaItem _media;
        IntPtr _audio;
        WMPPlayState _playState = WMPPlayState.wmppsUndefined;
        WMPOpenState _openState = WMPOpenState.wmposUndefined;
        Timer _timer;
        string _uiMode = "none";
        bool _enableContextMenu, _windowlessVideo, _stretchToFit, _fullScreen;

        Player()
        {
#if !XP
            _library = new Library(_collection);
#endif
            _controls = new Controls(this);
            Settings = new Settings(this);
            _playlists = new PlaylistCollection(this);
            Use(new Playlist(""));
            WatchLibrary();
        }

        // Files that come and go in the library folders (native/platform/watch.m)
        // are looked for every two seconds, on Media Center's UI thread: when
        // there have been some, the library is scanned again on the next
        // question, and Media Center hears of it as Windows Media Player tells
        // it (MediaCollectionChange), and refreshes what it shows.
        Timer _libraryWatch;
        int _libraryChanges;

        void WatchLibrary()
        {
            _libraryChanges = MediaLibrary.Changes;
            try
            {
                _libraryWatch = new Timer();
                _libraryWatch.Interval = 2000;
                _libraryWatch.AutoRepeat = true;
                _libraryWatch.Tick += delegate
                {
                    int now = MediaLibrary.Changes;
                    if (now == _libraryChanges) return;
                    _libraryChanges = now;
                    ComTodo.Log("wmp", "library folders changed: looking again");
                    MediaLibrary.Invalidate();
                    if (MediaCollectionChange_handler != null) MediaCollectionChange_handler();
                };
                _libraryWatch.Start();
            }
            catch (Exception e)
            {
                ComTodo.Log("wmp", "library folders not watched: " + e.Message);
            }
        }

        // ---- events -------------------------------------------------------------

        void SetPlayState(WMPPlayState state)
        {
            if (_playState == state) return;
            _playState = state;
            ComTodo.Log("wmp", "play state " + state);
            if (PlayStateChange_handler != null) PlayStateChange_handler((int)state);
        }

        void SetOpenState(WMPOpenState state)
        {
            _openState = state;
            if (OpenStateChange_handler != null) OpenStateChange_handler((int)state);
        }

        internal void RaiseModeChange(string mode, bool value)
        {
            if (ModeChange_handler != null) ModeChange_handler(mode, value);
        }

        internal void RaisePlaylistCollectionChange()
        {
            if (PlaylistCollectionChange_handler != null) PlaylistCollectionChange_handler();
        }

        void PlaylistChanged(Playlist playlist, WMPPlaylistChangeEventType change)
        {
            if (PlaylistChange_handler != null) PlaylistChange_handler(playlist, change);
            if (ReferenceEquals(playlist, _playlist) && CurrentPlaylistChange_handler != null) CurrentPlaylistChange_handler(change);
        }

        // ---- the current playlist and item -----------------------------------------

        void Use(Playlist playlist)
        {
            if (_playlist != null) _playlist.Changed = null;
            _playlist = playlist;
            _playlist.Changed = PlaylistChanged;
        }

        internal Playlist Current { get { return _playlist; } }
        internal MediaItem Media { get { return _media; } }
        internal IntPtr Audio { get { return _audio; } }
        internal WMPPlayState PlayState { get { return _playState; } }

        void CloseAudio()
        {
            if (_audio != IntPtr.Zero)
            {
                Native.wmc_audio_close(_audio);
                _audio = IntPtr.Zero;
            }
        }

        internal void ApplyVolume()
        {
            if (_audio == IntPtr.Zero) return;
            Native.wmc_audio_set_volume(_audio, Settings.Mute ? 0f : Settings.Volume / 100f);
            Native.wmc_audio_set_rate(_audio, (float)Settings.Rate);
        }

        // Makes an item the current one and (for sound) starts it.
        internal void Start(MediaItem item)
        {
            CloseAudio();
            _media = item;
            SetOpenState(WMPOpenState.wmposMediaChanging);
            if (CurrentItemChange_handler != null) CurrentItemChange_handler(item);
            if (item == null)
            {
                SetPlayState(WMPPlayState.wmppsStopped);
                return;
            }
            SetOpenState(WMPOpenState.wmposMediaOpening);
            SetPlayState(WMPPlayState.wmppsTransitioning);
            if (item.Kind == "audio") _audio = Native.wmc_audio_open(item.Path);
            if (_audio == IntPtr.Zero)
            {
                // Not something that can be played here.
                ComTodo.Log("wmp", "cannot play " + item.Path);
                if (MediaError_handler != null) MediaError_handler(item);
                SetPlayState(WMPPlayState.wmppsReady);
                return;
            }
            SetOpenState(WMPOpenState.wmposMediaOpen);
            ApplyVolume();
            Native.wmc_audio_play(_audio);
            SetPlayState(WMPPlayState.wmppsPlaying);
            Watch();
        }

        void Watch()
        {
            if (_timer == null)
            {
                _timer = new Timer();
                _timer.Interval = 200;
                _timer.AutoRepeat = true;
                _timer.Tick += delegate { Tick(); };
            }
            _timer.Start();
        }

        void Tick()
        {
            if (_audio == IntPtr.Zero || _playState != WMPPlayState.wmppsPlaying)
            {
                if (_playState != WMPPlayState.wmppsPaused && _timer != null) _timer.Stop();
                return;
            }
            if (Native.wmc_audio_state(_audio) != 2) return;
            // The song played to its end: on to the next, or stop.
            SetPlayState(WMPPlayState.wmppsMediaEnded);
            MediaItem next = Neighbour(1, false);
            if (next != null)
            {
                Start(next);
            }
            else
            {
                CloseAudio();
                SetPlayState(WMPPlayState.wmppsTransitioning);
                SetPlayState(WMPPlayState.wmppsStopped);
            }
        }

        // The item before or after the current one in the playlist, minding
        // the shuffle and repeat modes. `wrap` is for the Next and Previous
        // buttons, which go round even without repeat.
        internal MediaItem Neighbour(int step, bool wrap)
        {
            int count = _playlist.Items.Count;
            if (count == 0) return null;
            int index = _media != null ? _playlist.Items.IndexOf(_media) : -1;
            if (Settings.GetMode("shuffle") && count > 1)
            {
                int pick;
                do { pick = _random.Next(count); } while (pick == index);
                return _playlist.Items[pick];
            }
            int target = index + step;
            if (target < 0 || target >= count)
            {
                if (!wrap && !Settings.GetMode("loop")) return null;
                target = (target + count) % count;
            }
            return _playlist.Items[target];
        }

        internal void Play()
        {
            if (_audio != IntPtr.Zero && _playState == WMPPlayState.wmppsPaused)
            {
                Native.wmc_audio_play(_audio);
                SetPlayState(WMPPlayState.wmppsPlaying);
                Watch();
            }
            else if (_audio != IntPtr.Zero && _playState == WMPPlayState.wmppsPlaying)
            {
            }
            else if (_media != null) Start(_media);
            else if (_playlist.Items.Count > 0) Start(_playlist.Items[0]);
        }

        internal void Pause()
        {
            if (_audio == IntPtr.Zero || _playState != WMPPlayState.wmppsPlaying) return;
            Native.wmc_audio_pause(_audio);
            SetPlayState(WMPPlayState.wmppsPaused);
        }

        internal void Stop()
        {
            CloseAudio();
            if (_playState != WMPPlayState.wmppsUndefined) SetPlayState(WMPPlayState.wmppsStopped);
        }

        internal void SetCurrentItem(MediaItem item)
        {
            if (item == null) return;
            bool playing = _playState == WMPPlayState.wmppsPlaying;
            if (playing) Start(item);
            else
            {
                CloseAudio();
                _media = item;
                if (CurrentItemChange_handler != null) CurrentItemChange_handler(item);
            }
        }

        internal void Seek(double seconds)
        {
            if (_audio == IntPtr.Zero) return;
            double old = Native.wmc_audio_position(_audio);
            Native.wmc_audio_set_position(_audio, seconds);
            if (PositionChange_handler != null) PositionChange_handler(old, seconds);
        }

        // ---- IWMPPlayer4 ----------------------------------------------------------

        public override IWMPControls get_controls() { return _controls; }
        public override IWMPSettings get_settings() { return Settings; }
        public override IWMPNetwork get_network() { return _network; }
        public override IWMPMediaCollection get_mediaCollection() { return _collection; }
        public override IWMPPlaylistCollection get_playlistCollection() { return _playlists; }
        public override IWMPCdromCollection get_cdromCollection() { return _cdroms; }
        public override IWMPPlayerApplication get_playerApplication() { return _application; }
        public override IWMPError get_Error() { return null; }
        public override IWMPMedia get_currentMedia() { return _media; }
        public override IWMPPlaylist get_currentPlaylist() { return _playlist; }
        public override WMPPlayState get_playState() { return _playState; }
        public override WMPOpenState get_openState() { return _openState; }
        // Media Center drives the Player "remotely": as a control attached to
        // the user's own Windows Media Player and its library. Several of its
        // features (the watched folders among them) are tied to that mode.
        public override bool get_isRemote() { return true; }
        public override bool get_isOnline() { return true; }
        public override bool get_enabled() { return true; }
        public override void set_enabled(bool value) { }
        public override string get_status() { return ""; }
        public override string get_versionInfo() { return "12.0.9600.16384"; }
        public override string get_uiMode() { return _uiMode; }
        public override void set_uiMode(string value)
        {
            _uiMode = value ?? "none";
            // The "custom" mode loads Media Center's skin, whose script
            // gives Media Center the visualization functions (Visualizations.cs).
            if (string.Equals(_uiMode, "custom", StringComparison.OrdinalIgnoreCase)) ConnectSkin();
        }

        // The site Media Center gave the control (AxHost.Site): it hands out
        // Media Center's own script object, which takes the skin's functions.
        public object Site;
        readonly VisualizationSkin _skin = new VisualizationSkin();

        void ConnectSkin()
        {
#if !XP   // (XP Media Center Edition's visualizations are not connected yet)
            var services = Site as IWMPRemoteMediaServices;
            if (services == null) return;
            try
            {
                string name;
                object scriptable;
                services.GetScriptableObject(out name, out scriptable);
                var dispatch = scriptable as EHMedia.SkinDispatch;
                if (dispatch != null) dispatch.SkinFunctionPointers = _skin;
            }
            catch (Exception e)
            {
                ComTodo.Log("wmp", "skin: " + e.Message);
            }
#endif
        }
        public override bool get_enableContextMenu() { return _enableContextMenu; }
        public override void set_enableContextMenu(bool value) { _enableContextMenu = value; }
        public override bool get_windowlessVideo() { return _windowlessVideo; }
        public override void set_windowlessVideo(bool value) { _windowlessVideo = value; }
        public override bool get_stretchToFit() { return _stretchToFit; }
        public override void set_stretchToFit(bool value) { _stretchToFit = value; }
        public override bool get_fullScreen() { return _fullScreen; }
        public override void set_fullScreen(bool value) { _fullScreen = value; }
        public override string get_URL() { return _media != null ? _media.Path : ""; }

        public override void set_URL(string url)
        {
            var item = MediaLibrary.Find(url) ?? MediaLibrary.Create(url);
            set_currentPlaylist(new Playlist("", new[] { item }));
        }

        public override void set_currentPlaylist(IWMPPlaylist value)
        {
            var playlist = value as Playlist ?? new Playlist("");
            SetOpenState(WMPOpenState.wmposPlaylistChanging);
            Use(playlist);
            if (CurrentPlaylistChange_handler != null) CurrentPlaylistChange_handler(WMPPlaylistChangeEventType.wmplcUnknown);
            SetOpenState(WMPOpenState.wmposPlaylistChanged);
            if (playlist.Items.Count == 0)
            {
                CloseAudio();
                _media = null;
                SetOpenState(WMPOpenState.wmposPlaylistOpenNoMedia);
            }
            else if (Settings.AutoStart) Start(playlist.Items[0]);
            else
            {
                CloseAudio();
                _media = playlist.Items[0];
                if (CurrentItemChange_handler != null) CurrentItemChange_handler(_media);
            }
        }

        public override void set_currentMedia(IWMPMedia value)
        {
            var item = value as MediaItem;
            if (item == null) return;
            if (!_playlist.Items.Contains(item))
            {
                set_currentPlaylist(new Playlist("", new[] { item }));
                return;
            }
            if (Settings.AutoStart) Start(item); else SetCurrentItem(item);
        }

        public override IWMPMedia newMedia(string url) { return MediaLibrary.Find(url) ?? MediaLibrary.Create(url); }
        public override IWMPPlaylist newPlaylist(string name, string url) { return new Playlist(name); }
        public override void close()
        {
            Stop();
            _media = null;
        }

#if !XP   // (library and folder services: not in Windows Media Player 10)
        // ---- IWMPLibraryServices, IWMPPlayerServices2 ---------------------------------

        public override int getCountByType(WMPLibraryType type)
        {
            return type == WMPLibraryType.wmpltLocal || type == WMPLibraryType.wmpltAll ? 1 : 0;
        }

        public override IWMPLibrary getLibraryByType(WMPLibraryType type, int index)
        {
            return (type == WMPLibraryType.wmpltLocal || type == WMPLibraryType.wmpltAll) && index == 0 ? _library : null;
        }

        public override void setBackgroundProcessingPriority(string priority) { }
        public override void setTaskPane(string pane) { }
        public override void setTaskPaneURL(string pane, string url, string friendlyName) { }

        // ---- IWMPFolderMonitorServices: the folders the library is made from ----------

        public override int get_count() { return MediaLibrary.Folders.Count; }
        public override string Item(int index)
        {
            var folders = MediaLibrary.Folders;
            return index >= 0 && index < folders.Count ? folders[index] : "";
        }
        public override WMPFolderScanState get_scanState() { return WMPFolderScanState.wmpfssStopped; }
        public override string get_currentFolder() { return ""; }
        public override int get_scannedFilesCount() { return MediaLibrary.Items.Count; }
        public override int get_addedFilesCount() { return 0; }
        public override int get_updateProgress() { return 100; }
        public override void startScan() { }
        public override void stopScan() { }
#endif
    }

    public sealed class Controls : ControlsBase
    {
        readonly Player _player;
        public Controls(Player player) { _player = player; }

        public override void play() { _player.Play(); }
        public override void pause() { _player.Pause(); }
        public override void stop() { _player.Stop(); }
        public override void next()
        {
            var item = _player.Neighbour(1, true);
            if (item != null) _player.Start(item);
        }
        public override void previous()
        {
            var item = _player.Neighbour(-1, true);
            if (item != null) _player.Start(item);
        }
        public override void playItem(IWMPMedia media)
        {
            var item = media as MediaItem;
            if (item != null) _player.Start(item);
        }
        public override IWMPMedia get_currentItem() { return _player.Media; }
        public override void set_currentItem(IWMPMedia media) { _player.SetCurrentItem(media as MediaItem); }
        public override double get_currentPosition()
        {
            return _player.Audio != IntPtr.Zero ? Native.wmc_audio_position(_player.Audio) : 0;
        }
        public override void set_currentPosition(double seconds) { _player.Seek(seconds); }
        public override string get_currentPositionString()
        {
            int s = (int)get_currentPosition();
            return string.Format("{0:00}:{1:00}", s / 60, s % 60);
        }
        public override bool get_isAvailable(string item) { return true; }
        public override int get_currentMarker() { return 0; }
        public override int get_audioLanguageCount() { return 0; }
    }

    public sealed class Settings : SettingsBase
    {
        readonly Player _player;
        readonly Dictionary<string, bool> _modes = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase) { { "autoRewind", true } };
        public bool AutoStart = true, Mute, ErrorDialogs, InvokeUrls;
        public int Volume = 100, Balance, PlayCount = 1;
        public double Rate = 1;

        public Settings(Player player) { _player = player; }

        public bool GetMode(string mode)
        {
            bool v;
            return _modes.TryGetValue(mode ?? "", out v) && v;
        }

        public override bool get_autoStart() { return AutoStart; }
        public override void set_autoStart(bool value) { AutoStart = value; }
        public override bool get_mute() { return Mute; }
        public override void set_mute(bool value) { Mute = value; _player.ApplyVolume(); }
        public override int get_volume() { return Volume; }
        public override void set_volume(int value) { Volume = Math.Max(0, Math.Min(100, value)); _player.ApplyVolume(); }
        public override double get_rate() { return Rate; }
        public override void set_rate(double value) { if (value > 0) { Rate = value; _player.ApplyVolume(); } }
        public override int get_balance() { return Balance; }
        public override void set_balance(int value) { Balance = value; }
        public override int get_playCount() { return PlayCount; }
        public override void set_playCount(int value) { PlayCount = value; }
        public override bool get_enableErrorDialogs() { return ErrorDialogs; }
        public override void set_enableErrorDialogs(bool value) { ErrorDialogs = value; }
        public override bool get_invokeURLs() { return InvokeUrls; }
        public override void set_invokeURLs(bool value) { InvokeUrls = value; }
        public override bool get_isAvailable(string item) { return true; }
        public override bool getMode(string mode) { return GetMode(mode); }
        public override void setMode(string mode, bool value)
        {
            if (GetMode(mode) == value) return;
            _modes[mode ?? ""] = value;
            _player.RaiseModeChange(mode, value);
        }
        public override string get_baseURL() { return ""; }
        public override string get_defaultFrame() { return ""; }
        public override string get_mediaAccessRights() { return "full"; }
        public override bool requestMediaAccessRights(string access) { return true; }
    }

    // The Player program itself. There is none: playback always stays with
    // the control inside Media Center ("docked").
    public sealed class PlayerApplication : PlayerApplicationBase
    {
        public override bool get_playerDocked() { return true; }
        public override bool get_hasDisplay() { return false; }
        public override void switchToControl() { }
        public override void switchToPlayerApplication() { }
    }

    // Local files need no buffering.
    public sealed class Network : NetworkBase
    {
        public override int get_bufferingProgress() { return 100; }
        public override int get_downloadProgress() { return 100; }
        public override int get_bufferingCount() { return 0; }
    }

    // No disc drives.
    public sealed class CdromCollection : CdromCollectionBase
    {
        public override int get_count() { return 0; }
        public override IWMPCdrom Item(int index) { return null; }
        public override IWMPCdrom getByDriveSpecifier(string drive) { return null; }
    }

    // The user's own playlists. Kept for the session only.
    public sealed class PlaylistCollection : PlaylistCollectionBase
    {
        readonly Player _player;
        readonly List<Playlist> _playlists = new List<Playlist>();
        public PlaylistCollection(Player player) { _player = player; }

        public override IWMPPlaylist newPlaylist(string name)
        {
            var p = new Playlist(name);
            _playlists.Add(p);
            _player.RaisePlaylistCollectionChange();
            return p;
        }
        public override IWMPPlaylistArray getAll() { return new PlaylistArray(_playlists); }
        public override IWMPPlaylistArray getByName(string name)
        {
            return new PlaylistArray(_playlists.FindAll(p => string.Equals(p.get_name(), name, StringComparison.CurrentCultureIgnoreCase)));
        }
        public override IWMPPlaylist importPlaylist(IWMPPlaylist item)
        {
            var source = item as Playlist;
            if (source == null) return null;
            var copy = new Playlist(source.get_name(), source.Items);
            _playlists.Add(copy);
            _player.RaisePlaylistCollectionChange();
            return copy;
        }
        public override void remove(IWMPPlaylist item)
        {
            var p = item as Playlist;
            if (p != null && _playlists.Remove(p)) _player.RaisePlaylistCollectionChange();
        }
        public override bool isDeleted(IWMPPlaylist item) { return false; }
    }

    public sealed class PlaylistArray : PlaylistArrayBase
    {
        readonly List<Playlist> _items;
        public PlaylistArray(List<Playlist> items) { _items = new List<Playlist>(items); }
        public override int get_count() { return _items.Count; }
        public override IWMPPlaylist Item(int index) { return index >= 0 && index < _items.Count ? _items[index] : null; }
    }
}
