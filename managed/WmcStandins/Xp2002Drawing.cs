// XP Media Center Edition 2002 makes thumbnails and full-screen pictures
// with System.Drawing, then hands them to its engine (ehuihlp.dll) as GDI
// bitmaps: Bitmap.GetHbitmap, and Image.FromHbitmap for the thumbnails it
// keeps. Under Mono those are libgdiplus's own handles, which the engine
// here (native/duser) cannot read. These take the place of the two calls
// (redirects.txt, [xp2002]): the pixels are copied into, and out of, the
// stand-in library's GDI bitmaps (native/win32/gdi32_objects.c).
#if XP2002
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace WmcStandins
{
    public static partial class Compat
    {
        [DllImport("wmcshim")]
        static extern IntPtr wmc_gdi_bitmap_from_pixels(int width, int height, int stride, IntPtr pixels);

        [DllImport("wmcshim")]
        static extern int wmc_gdi_bitmap_size(IntPtr bitmap, out int width, out int height);

        [DllImport("wmcshim")]
        static extern int wmc_gdi_bitmap_copy_pixels(IntPtr bitmap, IntPtr pixels, int stride);

        public static IntPtr Bitmap_GetHbitmap(Bitmap bitmap)
        {
            if (bitmap == null || bitmap.Width <= 0 || bitmap.Height <= 0) return IntPtr.Zero;
            var data = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try { return wmc_gdi_bitmap_from_pixels(bitmap.Width, bitmap.Height, data.Stride, data.Scan0); }
            finally { bitmap.UnlockBits(data); }
        }

        // (with a background colour for transparent pixels: Windows' GDI
        // bitmaps have no alpha; the engine is told they do not either)
        public static IntPtr Bitmap_GetHbitmap(Bitmap bitmap, Color background)
        {
            return Bitmap_GetHbitmap(bitmap);
        }

        public static Bitmap Image_FromHbitmap(IntPtr hbitmap)
        {
            int width, height;
            if (wmc_gdi_bitmap_size(hbitmap, out width, out height) == 0) throw new ArgumentException("not a bitmap", "hbitmap");
            var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
            var data = bitmap.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            try { wmc_gdi_bitmap_copy_pixels(hbitmap, data.Scan0, data.Stride); }
            finally { bitmap.UnlockBits(data); }
            return bitmap;
        }

        public static Bitmap Image_FromHbitmap(IntPtr hbitmap, IntPtr palette)
        {
            return Image_FromHbitmap(hbitmap);
        }
    }
}
#endif
