"""Tertiary Planner icon: red gradient, white calendar page with binder rings,
crimson header, bold red checkmark. Draws at 4x and downsamples for clean edges."""
import sys
from PIL import Image, ImageDraw, ImageFilter

SS = 4  # supersampling factor

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))

def gradient(size, top, bottom):
    """Diagonal gradient (top-left -> bottom-right)."""
    g = Image.new("RGB", (size, size))
    px = g.load()
    for y in range(size):
        for x in range(size):
            px[x, y] = lerp(top, bottom, (x + y) / (2 * size - 2))
    return g

def art(n):
    """Full-bleed artwork, n x n (already supersampled)."""
    small = gradient(256, (255, 92, 82), (200, 16, 46)).resize((n, n), Image.BICUBIC)
    img = small.convert("RGBA")
    u = n / 1024  # design units

    def R(x0, y0, x1, y1): return [x0 * u, y0 * u, x1 * u, y1 * u]

    # Soft shadow under the page.
    sh = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle(R(212, 272, 812, 852), radius=96 * u, fill=(90, 0, 10, 110))
    img = Image.alpha_composite(img, sh.filter(ImageFilter.GaussianBlur(28 * u)))

    d = ImageDraw.Draw(img)
    # Page body (white) and crimson header band.
    d.rounded_rectangle(R(212, 246, 812, 826), radius=96 * u, fill=(255, 255, 255, 255))
    header = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    hd = ImageDraw.Draw(header)
    hd.rounded_rectangle(R(212, 246, 812, 826), radius=96 * u, fill=(150, 10, 30, 255))
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rectangle(R(0, 0, 1024, 418), fill=255)
    img.paste(header, (0, 0), Image.composite(header.split()[3], mask, mask))
    d = ImageDraw.Draw(img)

    # Binder rings poking above the page.
    for cx in (382, 642):
        d.ellipse(R(cx - 30, 312, cx + 30, 372), fill=(110, 6, 22, 255))          # punch hole
        d.rounded_rectangle(R(cx - 26, 196, cx + 26, 346), radius=26 * u,
                            fill=(255, 255, 255, 255))                              # ring

    # Bold checkmark on the page.
    pts = [(368, 618), (474, 722), (668, 520)]
    w = 76
    d.line([(x * u, y * u) for x, y in pts], fill=(224, 36, 47, 255), width=int(w * u), joint="curve")
    for x, y in (pts[0], pts[2]):
        d.ellipse(R(x - w / 2, y - w / 2, x + w / 2, y + w / 2), fill=(224, 36, 47, 255))
    return img

def ios(out):
    a = art(1024 * SS).resize((1024, 1024), Image.LANCZOS).convert("RGB")  # no alpha for App Store
    a.save(out)

def mac(out_dir):
    n = 1024 * SS
    canvas = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    body = 824 * SS; off = (n - body) // 2; radius = 185 * SS
    tile = art(body)
    m = Image.new("L", (body, body), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, body - 1, body - 1], radius=radius, fill=255)
    shadow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([off, off + 14 * SS, off + body, off + body + 14 * SS],
                                             radius=radius, fill=(0, 0, 0, 90))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(14 * SS)))
    canvas.paste(tile, (off, off), m)
    big = canvas.resize((1024, 1024), Image.LANCZOS)
    for s in (16, 32, 64, 128, 256, 512, 1024):
        big.resize((s, s), Image.LANCZOS).save(f"{out_dir}/icon_{s}.png")

if __name__ == "__main__":
    ios(sys.argv[1]); mac(sys.argv[2])
