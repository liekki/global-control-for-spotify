// Draws Spoco.ico: a green Spotify-style logo with an air traffic control tower in front.
// build.cmd runs this before compiling Spoco. Pass a folder as the first argument to also dump PNG previews.
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

static class MakeIcon
{
    static readonly Color Green = Color.FromArgb(0x1E, 0xD7, 0x60);
    static readonly Color Dark = Color.FromArgb(0x19, 0x14, 0x14);
    static readonly Color Tower = Color.White;
    static readonly Color Glass = Color.FromArgb(0x2A, 0x3B, 0x4C);

    static void Main(string[] args)
    {
        int[] sizes = { 16, 20, 24, 32, 48, 64, 256 };
        var images = new Bitmap[sizes.Length];
        for (int i = 0; i < sizes.Length; i++)
        {
            images[i] = Draw(sizes[i]);
            if (args.Length > 0) images[i].Save(Path.Combine(args[0], "icon-" + sizes[i] + ".png"), ImageFormat.Png);
        }
        WriteIco("Spoco.ico", images);
    }

    // Everything is laid out on a 256x256 grid and scaled. Small sizes get thicker strokes so they stay readable.
    static Bitmap Draw(int size)
    {
        var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.ScaleTransform(size / 256f, size / 256f);
            bool small = size <= 24;

            g.FillEllipse(new SolidBrush(Green), 4, 4, 248, 248);

            // The three sound waves, widest on top.
            float[] y = { 78, 122, 162 }, half = { 92, 78, 62 }, width = { 26, 21, 17 }, bend = { 30, 24, 18 };
            for (int i = 0; i < 3; i++)
            {
                using (var pen = new Pen(Dark, small ? width[i] * 1.25f : width[i]) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                    g.DrawBezier(pen, 128 - half[i], y[i] + bend[i] * 0.3f, 128 - half[i] * 0.4f, y[i] - bend[i],
                                      128 + half[i] * 0.4f, y[i] - bend[i], 128 + half[i], y[i] + bend[i] * 0.6f);
            }

            // Tower: outlined in green so it separates from the dark waves behind it.
            using (var circle = new GraphicsPath())
            {
                circle.AddEllipse(4, 4, 248, 248);
                g.SetClip(circle);
            }
            var tower = new GraphicsPath();
            tower.AddPolygon(new[] { new PointF(110, 256), new PointF(118, 132), new PointF(138, 132), new PointF(146, 256) }); // shaft
            tower.AddPolygon(new[] { new PointF(104, 120), new PointF(152, 120), new PointF(140, 138), new PointF(116, 138) }); // cab base
            tower.AddPolygon(new[] { new PointF(80, 74), new PointF(176, 74), new PointF(156, 122), new PointF(100, 122) });    // cab
            tower.AddRectangle(new RectangleF(92, 62, 72, 14));                                                                 // roof
            tower.AddRectangle(new RectangleF(small ? 121 : 124, 30, small ? 14 : 8, 34));                                      // antenna
            tower.FillMode = FillMode.Winding;

            using (var outline = new Pen(Green, small ? 18 : 12) { LineJoin = LineJoin.Round })
                g.DrawPath(outline, tower);
            g.FillPath(new SolidBrush(Tower), tower);

            // Windows around the cab.
            var glass = new GraphicsPath();
            glass.AddPolygon(new[] { new PointF(90, 84), new PointF(166, 84), new PointF(155, 110), new PointF(101, 110) });
            g.FillPath(new SolidBrush(Glass), glass);
            if (!small)
            {
                using (var mullion = new Pen(Tower, 5))
                    foreach (float x in new float[] { 109, 128, 147 })
                        g.DrawLine(mullion, x, 84, x + (x - 128) * -0.15f, 110);
            }
        }
        return bmp;
    }

    // Small sizes go in as classic DIBs (most compatible), 256 as PNG like Windows' own icons.
    static void WriteIco(string path, Bitmap[] images)
    {
        var data = new byte[images.Length][];
        for (int i = 0; i < images.Length; i++)
            data[i] = images[i].Width >= 256 ? Png(images[i]) : Dib(images[i]);

        using (var w = new BinaryWriter(File.Create(path)))
        {
            w.Write((short)0); w.Write((short)1); w.Write((short)images.Length);
            int offset = 6 + 16 * images.Length;
            for (int i = 0; i < images.Length; i++)
            {
                int s = images[i].Width;
                w.Write((byte)(s >= 256 ? 0 : s)); w.Write((byte)(s >= 256 ? 0 : s));
                w.Write((byte)0); w.Write((byte)0);
                w.Write((short)1); w.Write((short)32);
                w.Write(data[i].Length); w.Write(offset);
                offset += data[i].Length;
            }
            foreach (var d in data) w.Write(d);
        }
    }

    static byte[] Png(Bitmap bmp)
    {
        using (var ms = new MemoryStream()) { bmp.Save(ms, ImageFormat.Png); return ms.ToArray(); }
    }

    static byte[] Dib(Bitmap bmp)
    {
        int s = bmp.Width, maskStride = ((s + 31) / 32) * 4;
        using (var ms = new MemoryStream())
        using (var w = new BinaryWriter(ms))
        {
            w.Write(40); w.Write(s); w.Write(s * 2); w.Write((short)1); w.Write((short)32);
            w.Write(0); w.Write(s * s * 4 + maskStride * s); w.Write(0); w.Write(0); w.Write(0); w.Write(0);
            for (int y = s - 1; y >= 0; y--)
                for (int x = 0; x < s; x++)
                {
                    Color c = bmp.GetPixel(x, y);
                    w.Write(c.B); w.Write(c.G); w.Write(c.R); w.Write(c.A);
                }
            for (int y = s - 1; y >= 0; y--)
            {
                var row = new byte[maskStride];
                for (int x = 0; x < s; x++)
                    if (bmp.GetPixel(x, y).A == 0) row[x / 8] |= (byte)(0x80 >> (x % 8));
                w.Write(row);
            }
            return ms.ToArray();
        }
    }
}
