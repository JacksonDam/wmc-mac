// Pictures decoded by the render engine (see managed/redirects.txt).
// Windows 7 and Vista: XP Media Center Edition's counterparts differ.
#if !XP

using Microsoft.MediaCenter.Interop;
using Microsoft.MediaCenter.UI;

namespace WmcStandins
{
    public static partial class Compat
    {
        // A picture's requirements go to the engine's decoder as a structure.
        // One field is a managed list of colour filters (for example the
        // grey of the "play favorites" picture wall), which Mono cannot pass
        // to native code. The engine never uses it: the framework applies
        // the filters itself once the picture is decoded. So the engine gets
        // the requirements without it.
        public static bool Bitmap_Decode(Microsoft.MediaCenter.UI.Drawing.BitmapInfo bitmap, ImageRequirements req,
                                         RenderApi.BitmapOptions options, out RenderApi.HSpBitmap hBmp, out RenderApi.ImageInformation info)
        {
            if (req != null && req.cfsFilterSet != null)
            {
                var plain = new ImageRequirements();
                plain.nMask = req.nMask & ~ImageRequirements.Fields.FilterSet;
                plain.sizeMaximumPxl = req.sizeMaximumPxl;
                plain.nBorderPxl = req.nBorderPxl;
                plain.clrBorder = req.clrBorder;
                req = plain;
            }
            return bitmap.DecodeBitmap(req, options, out hBmp, out info);
        }
    }
}

#endif
