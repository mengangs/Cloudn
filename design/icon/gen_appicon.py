# 应用图标：纸色底 + 陶土实心云，云里挖出向下箭头
# 用法：python gen_appicon.py <输出目录>（依赖 picosvg、cairosvg）
import sys, cairosvg
from picosvg import svg_pathops as sp
from picosvg.svg_types import SVGPath, SVGCircle, SVGRect

def P(d): return list(SVGPath(d=d).absolute(inplace=False).arcs_to_cubics(inplace=False).as_cmd_seq())
def C(cx, cy, r): return list(SVGCircle(cx=cx, cy=cy, r=r).as_path().absolute(inplace=False).arcs_to_cubics(inplace=False).as_cmd_seq())
def R(x, y, w, h, r): return list(SVGRect(x=x, y=y, width=w, height=h, rx=r, ry=r).as_path().absolute(inplace=False).arcs_to_cubics(inplace=False).as_cmd_seq())
def S(cmds, w): return list(sp.stroke(cmds, 'round', 'round', w, 4, 0.2))
def U(*s): return list(sp.union(s, ['nonzero'] * len(s)))
def D(a, b): return list(sp.difference([a, b], ['nonzero', 'nonzero']))
def fmt(cmds): return ''.join(c + ' '.join(('%.1f' % a).rstrip('0').rstrip('.') for a in args) for c, args in cmds)

cloud = U(R(188, 506, 648, 280, 140), C(372, 530, 152), C(598, 470, 212))
arrow = U(S(P('M512 462V700'), 66), S(P('M414 606L512 704L610 606'), 66))
mark = D(cloud, arrow)
d = fmt(mark)
open(sys.argv[1] + '/mark.d', 'w').write(d)

def icon(bg, fg, grad=None):
    bgfill = f'<rect width="1024" height="1024" fill="{bg}"/>' if bg else ''
    if grad:
        bgfill = f'<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{grad[0]}"/><stop offset="1" stop-color="{grad[1]}"/></linearGradient></defs><rect width="1024" height="1024" fill="url(#g)"/>'
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{bgfill}<path fill="{fg}" d="{d}"/></svg>'

out = sys.argv[1]
variants = {
    'Light': icon(None, '#B4532F', ('#FBF9F4', '#EFEBE2')),
    'Dark': icon(None, '#E08A66', ('#262421', '#161513')),
    'Tinted': icon('#000000', '#FFFFFF'),
}
for k, v in variants.items():
    open(f'{out}/AppIcon-{k}.svg', 'w').write(v)
    cairosvg.svg2png(bytestring=v.encode(), write_to=f'{out}/AppIcon-{k}.png', output_width=1024)
