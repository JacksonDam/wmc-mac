// XP Media Center Edition 2005 builds folder thumbnails with System.Drawing,
// drawing up to four small pictures into one. GDI+ on Windows draws nothing
// for an empty source or destination; Mono's libgdiplus makes an
// uninvertible cairo matrix of it and aborts the process, and some 24-bit
// sources leave it in the same broken state. These take the place of its
// two DrawImage calls (redirects.txt, [xp]): an empty draw is skipped, as
// on Windows, and a source in another format is drawn from a 32-bit copy.
#if XP
using System.Drawing;

namespace WmcStandins
{
    public static partial class Compat
    {
        // A 32-bit copy of a bitmap in another format, or null. (Its thumbnails
        // are 24-bit bitmaps over pixels it was given; libgdiplus draws some
        // of those into a broken state.)
        static Bitmap Argb(Image image)
        {
            var bmp = image as Bitmap;
            if (bmp == null || bmp.PixelFormat == System.Drawing.Imaging.PixelFormat.Format32bppArgb
                || bmp.PixelFormat == System.Drawing.Imaging.PixelFormat.Format32bppPArgb) return null;
            var rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
            var copy = new Bitmap(bmp.Width, bmp.Height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            var from = bmp.LockBits(rect, System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            var to = copy.LockBits(rect, System.Drawing.Imaging.ImageLockMode.WriteOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            try
            {
                var row = new byte[bmp.Width * 4];
                for (int y = 0; y < bmp.Height; y++)
                {
                    System.Runtime.InteropServices.Marshal.Copy(from.Scan0 + y * from.Stride, row, 0, row.Length);
                    System.Runtime.InteropServices.Marshal.Copy(row, 0, to.Scan0 + y * to.Stride, row.Length);
                }
            }
            finally
            {
                bmp.UnlockBits(from);
                copy.UnlockBits(to);
            }
            return copy;
        }

        public static void Graphics_DrawImage(Graphics g, Image image, Rectangle dest, int srcX, int srcY, int srcWidth,
                                              int srcHeight, GraphicsUnit unit)
        {
            if (image == null || dest.Width <= 0 || dest.Height <= 0 || srcWidth <= 0 || srcHeight <= 0
                || image.Width <= 0 || image.Height <= 0)
            {
                ComTodo.Log("draw", "DrawImage skipped: " + dest + " from " + srcX + "," + srcY + " " + srcWidth + "x" + srcHeight);
                return;
            }
            Bitmap copy = Argb(image);
            g.DrawImage(copy ?? image, dest, srcX, srcY, srcWidth, srcHeight, unit);
            if (copy != null) copy.Dispose();
        }

        public static void Graphics_DrawImage(Graphics g, Image image, RectangleF dest)
        {
            if (image == null || !(dest.Width > 0) || !(dest.Height > 0) || image.Width <= 0 || image.Height <= 0)
            {
                ComTodo.Log("draw", "DrawImage skipped: " + dest);
                return;
            }
            Bitmap copy = Argb(image);
            g.DrawImage(copy ?? image, dest);
            if (copy != null) copy.Dispose();
        }
    }
}
#endif
