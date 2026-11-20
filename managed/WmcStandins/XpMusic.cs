// XP Media Center Edition 2005 looks for an album's cover beside its songs:
// AlbumArt_{collection id}_Large.jpg, the file Windows Media Player 10 left
// in album folders. A Mac's songs carry their pictures inside them, and the
// music folders are the person's own, not to be written in. The library
// stand-in writes each album's picture into Media Center's art cache under
// that name when the collection id is asked for (Wmp/MediaItem.cs); this
// takes the place of EHMedia.EHMedia2.GetGuidArtFileName (redirects.txt,
// [xp]) so that XP looks there.
#if XP
using System;

namespace WmcStandins
{
    public static partial class Compat
    {
        public static string Xp_AlbumArtFile(EHMedia.EHMedia2 media, string folder)
        {
            string id = media.getItemInfo("WM/WMCollectionID");
            if (string.IsNullOrEmpty(id)) return null;
            string cache = Environment_GetFolderPath(Environment.SpecialFolder.LocalApplicationData) + "/Microsoft/eHome/Art Cache/";
            return System.IO.Path.Combine(cache, "AlbumArt_" + id + "_Large.jpg");
        }
    }
}
#endif
