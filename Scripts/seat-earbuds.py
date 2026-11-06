"""Derive the seated pose of the earbuds in Apple's AirPods Pro 3 USDZ.

The AR asset floats and tilts both earbuds above the open case, so a plain
downward translation leaves them tipped forward and they poke through the
closed lid. This script finds the rigid transform that seats the LEFT earbud:

1. Initial guess: align the earbud's two stem charging pads with the case's two
   gold charging contacts (pad normals, pad-to-pad direction) and the stem's
   principal axis with the socket's principal axis (weighted Kabsch).
2. Trimmed point-to-surface ICP against the socket, the deck/head cradle and
   the closed lid's inner lining.
3. Push-out refinement: earbud vertices that end up behind the cradle, socket
   or closed-lid surfaces are pushed out along the surface normal until the
   remaining penetration is negligible.

The right earbud is an exact mirror of the left (checked to 1e-4), so its seat
is the X-mirror of the left transform. The result is written to seat.json and
is embedded as a constant in render-closed-case.py.

/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
  --threads 8 --python Scripts/seat-earbuds.py
"""
import bpy
import json
import numpy as np
from pathlib import Path
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

root = Path(__file__).resolve().parent.parent
here = root / 'work' / 'case-renders'
here.mkdir(parents=True, exist_ok=True)
model = root / 'Assets' / 'airpods-pro.usdz'
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
bpy.ops.wm.usd_import(filepath=str(model))
for obj in bpy.data.objects:
    if obj.parent is None:
        obj.scale *= 50
bpy.context.view_layer.update()
O = bpy.data.objects

BUD, PAD_A, PAD_B = 'BLvfImZvTRtJYtd', 'dExUZHAdVilEsVU', 'VeazXbsmuJYoYDQ'
lid = O['kpaqGvvhsGowTJD']
body = O['ZnPUFrNzvqVdFKc']
lid.matrix_local = Matrix.Identity(4)          # closed (USD rotateX 0)
bpy.context.view_layer.update()


def meshes_under(root):
    res, stack = [], [root]
    while stack:
        o = stack.pop()
        if o.type == 'MESH':
            res.append(o)
        stack.extend(o.children)
    return res


def world_mesh(objs):
    verts, polys = [], []
    for o in objs:
        base = len(verts)
        verts.extend(tuple(o.matrix_world @ v.co) for v in o.data.vertices)
        polys.extend([base + i for i in p.vertices] for p in o.data.polygons)
    return np.array(verts), polys


def bvh(verts, polys, T=None):
    if T is not None:
        verts = verts @ T[:3, :3].T + T[:3, 3]
    return BVHTree.FromPolygons([Vector(v) for v in verts], polys)


def area_centroid_normal(obj, keep=lambda c: True):
    mw = obj.matrix_world
    nm = mw.to_3x3().inverted().transposed()
    c, n, a = Vector(), Vector(), 0.0
    for p in obj.data.polygons:
        pc = mw @ p.center
        if not keep(pc):
            continue
        c += pc * p.area
        n += (nm @ p.normal) * p.area
        a += p.area
    return np.array(c / a), np.array(n.normalized())


def principal_axis(P, origin):
    c = P.mean(0)
    w, v = np.linalg.eigh(np.cov((P - c).T))
    axis = v[:, -1]
    return axis if np.dot(axis, c - origin) > 0 else -axis


def kabsch(P, Q, w=None):
    w = np.ones(len(P)) if w is None else w
    pc = (P * w[:, None]).sum(0) / w.sum()
    qc = (Q * w[:, None]).sum(0) / w.sum()
    H = ((P - pc) * w[:, None]).T @ (Q - qc)
    U, S, Vt = np.linalg.svd(H)
    d = np.sign(np.linalg.det(Vt.T @ U.T))
    R = Vt.T @ np.diag([1, 1, d]) @ U.T
    T = np.eye(4)
    T[:3, :3] = R
    T[:3, 3] = qc - R @ pc
    return T


def kabsch_dirs(A, B, w):
    H = sum(wi * np.outer(a, b) for a, b, wi in zip(A, B, w))
    U, S, Vt = np.linalg.svd(H)
    d = np.sign(np.linalg.det(Vt.T @ U.T))
    return Vt.T @ np.diag([1, 1, d]) @ U.T


left = lambda c: c.x < 0
bud_meshes = meshes_under(O[BUD])
bud_v, bud_p = world_mesh(bud_meshes)
static_v, static_p = world_mesh(meshes_under(body) + meshes_under(lid))
static_bvh = bvh(static_v, static_p)

# 1. Initial guess from the charging contacts and the stem/socket axes.
ea, eb = area_centroid_normal(O[PAD_A]), area_centroid_normal(O[PAD_B])
gold = O['advrDHJnusZvnds']
inner = area_centroid_normal(gold, lambda c: c.x < 0 and abs(c.x) < 0.95)
outer = area_centroid_normal(gold, lambda c: c.x < 0 and abs(c.x) >= 0.95)
emid, cmid = (ea[0] + eb[0]) / 2, (inner[0] + outer[0]) / 2
shell = O['tkQHhRlfHIMNwbL']
sv = np.array([tuple(shell.matrix_world @ v.co) for v in shell.data.vertices])
stem_axis = principal_axis(sv[np.linalg.norm(sv - emid, axis=1) < 0.75], emid)
sock = O['XZacaenQyJvJYyR']
kv = np.array([tuple(sock.matrix_world @ v.co) for v in sock.data.vertices])
kv = kv[kv[:, 0] < 0]
socket_axis = principal_axis(kv[np.linalg.norm(kv - cmid, axis=1) < 0.75], cmid)

# Surfaces the seated earbud sits against. Sign +1: the mesh normals face the
# cavity; -1: the mesh is wound the other way (the lid's black lining).
cavity = [('XZacaenQyJvJYyR', 1), ('HhSKUyiiGoaqiUU', 1), ('KTcvXtIbSdrwngW', -1),
          ('etXDpdpusFylxpy', 1), ('lLRBiUEDBcysTnb', 1)]
targets = np.array([tuple(O[n].matrix_world @ p.center) for n, _ in cavity[:3]
                    for p in O[n].data.polygons if (O[n].matrix_world @ p.center).x < 0])
cavity_bvh = [(bvh(*world_mesh([O[n]])), sign) for n, sign in cavity]


def icp(T, trim, iters=25):
    for _ in range(iters):
        b = bvh(bud_v, bud_p, T)
        P, Q = [], []
        for q in targets:
            loc, n, i, d = b.find_nearest(Vector(q))
            if loc is not None and d < trim:
                P.append(tuple(loc))
                Q.append(q)
        T = kabsch(np.array(P), np.array(Q)) @ T
    return T


def penetration(T, radius=0.05):
    """Depth of each earbud vertex behind any cavity surface, and the push that
    would bring it back to the surface."""
    v = bud_v @ T[:3, :3].T + T[:3, 3]
    depth = np.zeros(len(v))
    push = np.zeros_like(v)
    for k, p in enumerate(v):
        pv = Vector(p)
        for tree, sign in cavity_bvh:
            loc, n, i, d = tree.find_nearest(pv, radius)
            if loc is None:
                continue
            n = n * sign
            s = (pv - loc).dot(n)
            if s < 0 and -s > depth[k]:
                depth[k] = -s
                push[k] = np.array(n) * -s
    return v, depth, push


def overlaps(T):
    return len(bvh(bud_v, bud_p, T).overlap(static_bvh))


best = None
for pair in ((inner, outer), (outer, inner)):
    ca, cb = pair
    A = [ea[1], eb[1], (eb[0] - ea[0]) / np.linalg.norm(eb[0] - ea[0]), stem_axis]
    B = [-ca[1], -cb[1], (cb[0] - ca[0]) / np.linalg.norm(cb[0] - ca[0]), socket_axis]
    R = kabsch_dirs(A, B, [1, 1, 1, 3])
    T = np.eye(4)
    T[:3, :3] = R
    T[:3, 3] = cmid - R @ emid
    for trim in (0.15, 0.08, 0.04):
        T = icp(T, trim)
    v = bud_v @ T[:3, :3].T + T[:3, 3]
    outside = int(((np.abs(v[:, 0]) > 1.551) | (np.abs(v[:, 1]) > 0.546) |
                   (v[:, 2] < -1.662) | (v[:, 2] > 0.7025)).sum())
    score = overlaps(T) + 10 * outside
    print('candidate overlaps+outside score', score)
    if best is None or score < best[0]:
        best = (score, T)
T = best[1]
_, depth, _ = penetration(T)
print('after ICP: overlaps', overlaps(T), 'max penetration', depth.max().round(4),
      'p95', np.percentile(depth[depth > 0], 95).round(4) if (depth > 0).any() else 0)

# 3. Push-out: move penetrating vertices out along the surface normal; all
# other vertices act as weak anchors so the pose only moves as much as needed.
margin = 0.001
best = (depth.max(), T)
for it in range(60):
    v, depth, push = penetration(T)
    pen = depth > 0
    if depth.max() < best[0]:
        best = (depth.max(), T)
    if not pen.any():
        break
    unit = push / np.maximum(depth, 1e-9)[:, None]
    tgt = v + push + margin * unit * pen[:, None]
    w = np.where(pen, 1.0, 0.02)
    T = kabsch(v, tgt, w) @ T
    if it % 10 == 0:
        print(f'push-out it{it}: penetrating {pen.sum()} max {depth.max():.4f} '
              f'p95 {np.percentile(depth[pen], 95):.4f}')
T = best[1]
_, depth, _ = penetration(T)
stats = {
    'overlappingTrianglePairs': overlaps(T),
    'maxPenetration': float(depth.max()),
    'p95Penetration': float(np.percentile(depth[depth > 0], 95)) if (depth > 0).any() else 0.0,
}
print('final', stats)
(here / 'seat.json').write_text(json.dumps({'leftWorldTransform': T.tolist(), 'stats': stats}, indent=2) + '\n')
print('Wrote', here / 'seat.json')
