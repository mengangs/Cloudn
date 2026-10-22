# 生成实心平台图标：补画的用布尔运算拍平成纯填充路径；Simple Icons 有的直接取
# 用法：python gen_solid.py <输出目录> <simple-icons/icons 目录>（依赖 picosvg）
import os, re, sys
from picosvg import svg_pathops as sp
from picosvg.svg_types import SVGPath, SVGCircle, SVGRect
from picosvg.svg_transform import Affine2D

OUT = sys.argv[1]
SI = sys.argv[2]

def P(d):
    return list(SVGPath(d=d).absolute(inplace=False).arcs_to_cubics(inplace=False).as_cmd_seq())
def C(cx, cy, r):
    return list(SVGCircle(cx=cx, cy=cy, r=r).as_path().absolute(inplace=False).arcs_to_cubics(inplace=False).as_cmd_seq())
def R(x, y, w, h, r):
    return list(SVGRect(x=x, y=y, width=w, height=h, rx=r, ry=r).as_path().absolute(inplace=False).arcs_to_cubics(inplace=False).as_cmd_seq())
def S(cmds, w):
    return list(sp.stroke(cmds, 'round', 'round', w, 4, 0.05))
def T(cmds, s, dx=0, dy=0):
    return list(sp.transform(cmds, Affine2D(s, 0, 0, s, 24 - 24 * s + dx, 24 - 24 * s + dy)))
def U(*seqs):
    return list(sp.union(seqs, ['nonzero'] * len(seqs)))
def D(a, *bs):
    return list(sp.difference([a, U(*bs) if len(bs) > 1 else bs[0]], ['nonzero', 'nonzero']))
def solid(d):  # 线稿闭合区域填满，并保留原描边的外轮廓
    p = P(d)
    return U(p, S(p, 3))

def fmt(cmds):
    out = []
    for c, args in cmds:
        out.append(c + ' '.join(('%.2f' % a).rstrip('0').rstrip('.') for a in args))
    return ''.join(out)

def write(name, cmds, vb=48):
    os.makedirs(OUT, exist_ok=True)
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="{vb}" height="{vb}" viewBox="0 0 {vb} {vb}"><path fill="#000000" d="{fmt(cmds)}"/></svg>'
    open(os.path.join(OUT, name + '.svg'), 'w').write(svg)

badge_circle = C(24, 24, 22.5)
badge_square = R(2, 2, 44, 44, 11)

# 夸克：实心圆，挖出 Q 形
write('quark', D(badge_circle, S(P('M36 24c0 .878-.284 4.274-1.127 4.283c-7.274.07-7.959-.899-8.983 6.588C25.751 35.885 25.072 36 24 36c-6.627 0-12-5.373-12-12s5.373-12 12-12s12 5.373 12 12'), 3.4)))

# UC：实心圆，挖出松鼠
uc = ['M29.384 38.58s5.985-1.098 5.985 3.92H16.524c-6.184 0-11.197-5.013-11.197-11.197c0-2.9 1.1-5.548 2.914-7.533c3.51-3.84 5.1-5.194 5.1-8.375s-3.953-5.124-8.014-2.65C8.806 6.678 11.574 5.5 17.228 5.5s8.305 4.712 8.305 8.835c0 8.187-13.197 8.894-13.197 20.917',
      'M29.384 38.58a9.131 9.131 0 0 0-15.58-9.521',
      'M18.141 25.52c5.272-3.705 12.575-2.233 17.228 2.185c5.36-.943 7.304 2.356 7.304 2.356c-2.28-.178-5.034.656-6.854 1.343a3.04 3.04 0 0 1-3.336-.79c-3.593-3.961-9.133-7.585-14.342-5.093',
      'M22.98 23.573s2.789-2.863 8.973-6.175c-.236-3.004-.088-4.13 1.414-5.066c2.65.67 3.18 3.829 3.18 3.829c4.889 1.649 6.832 8.304 5.007 9.247s-7.741.256-11.353-.98']
uc_cuts = [S(T(P(d), 0.72), 2.4) for d in uc] + [S(T(C(19.584, 35.252, 7.248), 0.72), 2.4)]
write('uc', D(badge_circle, *uc_cuts))

# 迅雷：鸟形填满
write('xunlei', solid('M27.23 28.86c1.975 4.68 3.568 7.483 5.829 12.754c-3.485-4.045-7.909-7.71-11.865-9.59c-6.919-3.286-9.034-6.955-7.973-12.406c.874-4.493-4.014-7.132-7.72-8.782l6.98 2.197c3.186-1.652 6.249.742 7.987 3.717c6.248-5.128 12.675-8.52 19.859-10.364c-1.87 2.706-3.133 4.646-4.79 7.837l1.276-.283c-1.682 2.453-3.592 4.583-5.044 7.602c3.744.678 8.069 2.087 10.731 3.94c-5.338.804-10.627 1.673-15.27 3.377'))

# 115：实心圆，挖出数字
digits115 = ['M12.5 18l3-2v16', 'M21 18l3-2v16', 'M37 16h-6.5l-1 7.2c1-.8 2.2-1.2 3.5-1.2a4.5 4.5 0 0 1 0 9c-1.5 0-2.9-.7-3.8-1.8']
write('pan115', D(badge_circle, *[S(T(P(d), 0.92, 0.4), 3.2) for d in digits115]))

# 123：实心圆角方块，挖出数字（放大一些）
d123 = 'm13.5 20.684l2.278-1.24v9.112m3.659-6.094a3.022 3.022 0 0 1 3.618-2.96c1.266.243 2.277 1.337 2.403 2.62c.094.955-.208 1.896-.868 2.475c-1.22 1.071-5.153 3.96-5.153 3.96h6.038m3.558-.769c.63.527 1.309.769 2.834.769h.355a2.278 2.278 0 0 0 0-4.555m-3.19-3.797c.63-.526 1.31-.765 2.836-.761l.354.002a2.278 2.278 0 0 1 0 4.555m-1.751 0h1.751'
write('pan123', D(badge_square, S(T(P(d123), 1.45, 0.6, 0), 3.2)))

# 139：实心圆，挖出波纹
waves = ['M6 15.5S18 3 24 3s16 11 21 17', 'M12 21s10-11 15-11s18 15 18 15', 'M4 18s10 12 13 12s11-12 14-12s13 12 13 12',
         'M36 27S26 38 21 38S3 23 3 23', 'M42 32.5S30 45 24 45S8 34 3 28']
write('c139', D(badge_circle, *[S(T(P(d), 0.66), 2.6) for d in waves]))

# 光鸭：头、喙、身体填满，挖出眼睛
head = U(C(20, 15, 7.5), S(C(20, 15, 7.5), 3))
beak = solid('M27 14.5h7.5c-.5 2.5-2.5 4-5 4h-2.5')
body = solid('M13.5 19.5C8 22 6 26.5 6.5 31c.7 6 7 10.5 16.5 10.5S40.5 37 41.5 29c-4 2-9 2-13-1')
write('guangya', D(U(head, beak, body), C(21.5, 13.8, 2)))

# 蓝奏云：实心云，挖出 L
cloud = solid('M14 37.5h21a8.5 8.5 0 0 0 1.3-16.9A12 12 0 0 0 13 18.5a9.5 9.5 0 0 0 1 19z')
write('lanzou', D(cloud, S(P('M21 23.5v8h7'), 3.2)))
# 蓝奏优享：实心云，挖出星
star = P('M24.5 22l1.5 3 3.3.5-2.4 2.3.6 3.3-3-1.6-3 1.6.6-3.3-2.4-2.3 3.3-.5z')
write('ilanzou', D(cloud, U(T(star, 1.15, 0.3, 4.2), S(T(star, 1.15, 0.3, 4.2), 1.6))))

# AcFun：实心圆角方块，挖出 Ac
ac = ['M7 39L18.5 9L30 39', 'M11.5 28h14', 'M42 26.5a6 6 0 1 0 0 9']
write('acfun', D(badge_square, *[S(T(P(d), 0.66, -0.6, 0.4), 3.4) for d in ac]))

# OneDrive：前后两朵实心云，前云描边外再留一圈缝把后云切开
od_front = 'M38.5 38.5H19A5.5 5.5 0 1 1 21.04 27.89A9 9 0 1 1 38.98 27.52A5.5 5.5 0 0 1 38.5 38.5Z'
od_back = U(C(10.5, 25.5, 7), C(20.5, 18.5, 10), R(10.5, 22, 20, 10.5, 0))
write('onedrive', U(solid(od_front), D(od_back, S(P(od_front), 6))))

# 阿里云盘：外轮廓（含描边）与内轮廓之间的环带填满
ali_outer = 'M39.733 24.737c1.235-10.152-6.06-20.563-18.345-20.563C11.51 4.174 3.359 12.854 3.502 23.559c.131 9.814 8.629 19.028 17.887 20.104c9.812 1.141 19.368-3.722 23.033-14.041c.252-.71-.11-1.492-.998-1.709l-3.172-.773c-.883-.215-.718-.761-.518-2.403z'
ali_inner = P('M32.569 23.766c.761-5.816-3.807-11.409-9.591-11.972c-4.844-.472-11.916 2.574-11.836 11.934c.06 7.112 6.124 12.032 11.836 12.606c6.432.647 11.931-2.521 14.189-8.874c.155-.437-.078-.881-.615-1.052l-3.664-1.163c-.534-.17-.451-.47-.319-1.479z')
write('aliyun', D(solid(ali_outer), ali_inner))

# Simple Icons（CC0）
for name, src in [('baidu', 'baidu'), ('bilibili', 'bilibili'), ('douyin', 'tiktok'), ('kuaishou', 'kuaishou'),
                  ('weibo', 'sinaweibo'), ('pixiv', 'pixiv'), ('github', 'github'), ('gdrive', 'googledrive')]:
    s = open(os.path.join(SI, src + '.svg')).read()
    d = re.search(r'<path d="([^"]+)"', s).group(1)
    open(os.path.join(OUT, name + '.svg'), 'w').write(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path fill="#000000" d="{d}"/></svg>')
# 小红书：Simple Icons 只有文字，放进实心圆角方块里挖出来
xhs = re.search(r'<path d="([^"]+)"', open(os.path.join(SI, 'xiaohongshu.svg')).read()).group(1)
k = 2 * 0.8
write('xiaohongshu', D(badge_square, U(list(sp.transform(P(xhs), Affine2D(k, 0, 0, k, 24 - 12 * k, 24 - 12 * k))))))
print('done')
