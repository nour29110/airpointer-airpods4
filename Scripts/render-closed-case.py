"""Render the AirPointer case states from Apple's original AirPods Pro 3 USDZ.

Front view, case landscape (lid on top), ONE shared orthographic camera 12 deg
above the front so every output can crossfade:

  case-open.png     lid at the asset's articulated open angle, earbuds seated
  case-closed.png   lid closed, green status light lit
  lid/lid-NN.png    12 frames easing the lid from open (00) to closed (11)
  spin/spin-NNN.png 180 frames of the open case turning a full turn about its
                    vertical axis, 2 deg apart; spin-000 matches lid-00
  case-pointer.png  closed case turned a quarter CLOCKWISE about the camera's
                    viewing axis (object rotated, camera and lights fixed)
  *.json            source hash, camera, lid/LED state, silhouette, LED point
  review/           each still over a light and a dark stage, lid frame strip

/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
  --threads 8 --python Scripts/render-closed-case.py
Optional, after a "--": --only open,closed,pointer,lid,spin,review   --preview
"""
import bpy
import hashlib
import json
import math
import sys
import time
import numpy as np
from pathlib import Path
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree
from bpy_extras.object_utils import world_to_camera_view

args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
only = set(args[args.index('--only') + 1].split(',')) if '--only' in args else \
    {'open', 'closed', 'pointer', 'lid', 'spin', 'review'}
preview = '--preview' in args

# Renders land in work/ (ignored); the app bundles the copies in Assets/ (see Assets/README.md).
root = Path(__file__).resolve().parent.parent
out = root / 'work' / 'case-renders' / ('preview' if preview else '')
(out / 'lid').mkdir(parents=True, exist_ok=True)
(out / 'spin').mkdir(parents=True, exist_ok=True)
(out / 'review').mkdir(parents=True, exist_ok=True)
model = root / 'Assets' / 'airpods-pro.usdz'
source = 'https://www.apple.com/105/media/us/airpods-pro/2025/7acffb13-4adb-40b1-9393-8f1c99bc6c90/ar/airpods-pro.usdz'
source_sha = hashlib.sha256(model.read_bytes()).hexdigest()

STILL_SIZE, STILL_SAMPLES = (300, 32) if preview else (1200, 256)
FRAME_SIZE, FRAME_SAMPLES = (200, 24) if preview else (600, 128)
ELEVATION = 12.0          # degrees above the front face
ORTHO_SCALE = 4.4         # one framing for every output
TARGET = Vector((0, 0, -0.48))   # centre of the closed case's bounding box
LED_GREEN = '#30D158'      # target display colour of the lit status light
LED_RADIANCE = (0.0, 1.0, 0.12)   # scene-linear hue, see the status light notes
LED_STRENGTH = 0.65        # radiance at the dot centre
LED_RIM = 0.8              # radiance at the rim relative to the centre
LED_DISC = (0.08, 0.50)    # mask range over which the dot edge fades out
LID_OPEN = 115.0          # Apple's articulated open angle (USD rotateX -115)
FRAMES = 12
SPIN_FRAMES = 180          # one full turn, 2 deg apart (6 s at 30 fps)

# ---------------------------------------------------------------- model ----
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
bpy.ops.wm.usd_import(filepath=str(model))
for obj in bpy.data.objects:
    if obj.parent is None:
        obj.scale *= 50
bpy.context.view_layer.update()
O = bpy.data.objects
model_roots = [o for o in O if o.parent is None]

# Earbuds. Apple's AR pose floats AND tilts both earbuds above the case, so a
# plain drop leaves them tipped forward and through the closed lid. SEAT_LEFT
# is the world-space rigid transform that seats the left earbud: its stem
# charging pads registered onto the case's gold contacts, refined against the
# socket, head cradle and closed-lid lining (seat-earbuds.py derives it). The
# right earbud is an exact mirror, so it gets the X-mirrored transform.
SEAT_LEFT = Matrix((
    (0.727761992, -0.632034948, -0.266259849, -0.078957909),
    (0.682504428, 0.629241665, 0.371809942, 0.166918899),
    (-0.067455087, -0.452312670, 0.889304818, -1.617554823),
    (0.000000000, 0.000000000, 0.000000000, 1.000000000),
))
MIRROR_X = Matrix.Diagonal((-1, 1, 1, 1))
for name, seat in (('BLvfImZvTRtJYtd', SEAT_LEFT), ('bqtvQbjelRVbbzz', MIRROR_X @ SEAT_LEFT @ MIRROR_X)):
    O[name].matrix_world = seat @ O[name].matrix_world
bpy.context.view_layer.update()

# Lid. Prim kpaqGvvhsGowTJD carries the only articulation in the asset:
# translate:pivot (0, 0.11512405, -0.9922344), rotateXYZ (-115, 0, 0),
# !invert!translate:pivot. The hinge is the case's long (X) axis through that
# pivot, world (0, 0.4961, 0.0576) after the x50 scale: the rear rim. 0 deg
# seats the lid on the body.
lid = O['kpaqGvvhsGowTJD']
HINGE = Vector((0, 0.11512405, -0.9922344))


def set_lid(angle):
    lid.matrix_local = (Matrix.Translation(HINGE) @ Matrix.Rotation(math.radians(-angle), 4, 'X')
                        @ Matrix.Translation(-HINGE))
    bpy.context.view_layer.update()


# Status light. Mesh DkuOUpinUveIrMm (material IeVHhwRkexGaklQ) is Apple's
# 1.8 mm decal disc on the front face, centred 6 mm below the lid seam, with a
# green emission texture and a radial mask (MMeYzndLbGoAXKl). Rebuild its
# shading so one level (0 off .. 1 on) drives a soft lit dot. Off is fully
# transparent: the real Pro case shows nothing when the light is out. On is
# pure emission (no diffuse, specular or coat, which washed it out to mint).
# AgX cannot display #30D158 from non-negative light, so the radiance is a
# pure green that AgX renders close to it, slightly brighter at the centre.
led_obj = O['DkuOUpinUveIrMm']
led_mat = led_obj.material_slots[0].material
nt = led_mat.node_tree
bsdf = next(n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED')
mask_tex = next(n for n in nt.nodes if n.type == 'TEX_IMAGE' and n.image.name.startswith('MMeYzndLbGoAXKl'))
for link in list(nt.links):
    if link.to_node == bsdf:
        nt.links.remove(link)


def node(kind, **props):
    n = nt.nodes.new(kind)
    for k, v in props.items():
        setattr(n, k, v)
    return n


sep = node('ShaderNodeSeparateColor')
nt.links.new(mask_tex.outputs['Color'], sep.inputs['Color'])
disc = node('ShaderNodeMapRange', name='LED disc', interpolation_type='SMOOTHSTEP')
disc.inputs['From Min'].default_value, disc.inputs['From Max'].default_value = LED_DISC
nt.links.new(sep.outputs['Red'], disc.inputs['Value'])
profile = node('ShaderNodeMapRange', name='LED profile')
profile.inputs['To Min'].default_value = LED_RIM
nt.links.new(sep.outputs['Red'], profile.inputs['Value'])
level = node('ShaderNodeValue', name='LED level')
# Any level above zero makes the dot opaque. While the level ramps up the dot
# is a glossy pale-green lens (white -> green albedo, shell-like coat) that the
# emission takes over; fully lit it is pure emission. A part-lit frame thus
# reads as a dim green dot rather than a grey disc.
lit = node('ShaderNodeMath', operation='MULTIPLY', use_clamp=True)
lit.inputs[1].default_value = 20.0
nt.links.new(level.outputs['Value'], lit.inputs[0])
alpha = node('ShaderNodeMath', operation='MULTIPLY')
nt.links.new(disc.outputs['Result'], alpha.inputs[0])
nt.links.new(lit.outputs['Value'], alpha.inputs[1])
nt.links.new(alpha.outputs['Value'], bsdf.inputs['Alpha'])
lens = node('ShaderNodeMix', data_type='RGBA')
nt.links.new(level.outputs['Value'], lens.inputs['Factor'])
lens.inputs['A'].default_value = (1, 1, 1, 1)
lens.inputs['B'].default_value = LED_RADIANCE + (1.0,)
fade = node('ShaderNodeMath', operation='POWER')            # 1 - level^4
fade.inputs[1].default_value = 4.0
nt.links.new(level.outputs['Value'], fade.inputs[0])
unlit = node('ShaderNodeMath', operation='SUBTRACT')
unlit.inputs[0].default_value = 1.0
nt.links.new(fade.outputs['Value'], unlit.inputs[1])
albedo = node('ShaderNodeMix', data_type='RGBA', blend_type='MULTIPLY')
albedo.inputs['Factor'].default_value = 1.0
nt.links.new(lens.outputs['Result'], albedo.inputs['A'])
nt.links.new(unlit.outputs['Value'], albedo.inputs['B'])
nt.links.new(albedo.outputs['Result'], bsdf.inputs['Base Color'])
nt.links.new(unlit.outputs['Value'], bsdf.inputs['Coat Weight'])
specular = node('ShaderNodeMath', operation='MULTIPLY')
specular.inputs[1].default_value = 0.5
nt.links.new(unlit.outputs['Value'], specular.inputs[0])
nt.links.new(specular.outputs['Value'], bsdf.inputs['Specular IOR Level'])
glow = node('ShaderNodeMath', operation='MULTIPLY')
nt.links.new(profile.outputs['Result'], glow.inputs[0])
nt.links.new(level.outputs['Value'], glow.inputs[1])
strength = node('ShaderNodeMath', name='LED strength', operation='MULTIPLY')
strength.inputs[1].default_value = LED_STRENGTH
nt.links.new(glow.outputs['Value'], strength.inputs[0])
nt.links.new(strength.outputs['Value'], bsdf.inputs['Emission Strength'])
bsdf.inputs['Emission Color'].default_value = LED_RADIANCE + (1.0,)
bsdf.inputs['Roughness'].default_value = 1.0


def set_led(value):
    level.outputs['Value'].default_value = value


def meshes_under(root):
    res, stack = [], [root]
    while stack:
        o = stack.pop()
        if o.type == 'MESH':
            res.append(o)
        stack.extend(o.children)
    return res


def world_bvh(objs):
    verts, polys = [], []
    for o in objs:
        base = len(verts)
        verts.extend(o.matrix_world @ v.co for v in o.data.vertices)
        polys.extend([base + i for i in p.vertices] for p in o.data.polygons)
    return BVHTree.FromPolygons(verts, polys)


bud_bvh = world_bvh(meshes_under(O['BLvfImZvTRtJYtd']) + meshes_under(O['bqtvQbjelRVbbzz']))
lid_meshes = meshes_under(lid)


def lid_bud_overlaps():
    return len(world_bvh(lid_meshes).overlap(bud_bvh))


# ---------------------------------------------------------------- scene ----
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
device = 'CPU'
try:
    prefs = bpy.context.preferences.addons['cycles'].preferences
    prefs.compute_device_type = 'METAL'
    prefs.get_devices()
    metal = [d for d in prefs.devices if d.type == 'METAL']
    for d in prefs.devices:
        d.use = d.type == 'METAL'
    if metal:
        scene.cycles.device = 'GPU'
        device = 'METAL ' + metal[0].name
except (TypeError, ValueError, KeyError):
    pass
scene.cycles.use_denoising = True
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
scene.render.film_transparent = True
scene.view_settings.view_transform = 'AgX'
scene.view_settings.look = 'AgX - Medium High Contrast'
scene.view_settings.exposure = 0.2
scene.world.use_nodes = True
background = scene.world.node_tree.nodes['Background']
# A dark room, so the glossy shell reflects dark at grazing angles and the
# strip lights below read as crisp highlight bands, like a product shot.
background.inputs['Color'].default_value = (0.02, 0.02, 0.022, 1)
background.inputs['Strength'].default_value = 1.0


def aim(obj, target):
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat('-Z', 'Y').to_euler()


def softbox(name, location, power, width, height):
    light = bpy.data.lights.new(name, 'AREA')
    light.energy = power
    light.shape = 'RECTANGLE'
    light.size, light.size_y = width, height
    obj = bpy.data.objects.new(name, light)
    scene.collection.objects.link(obj)
    obj.location = location
    aim(obj, TARGET)


# A soft key and fill shape the case; the thin strips are what its gloss
# reflects, and the rim separates it from the dark stage.
softbox('Key', (-4, -6, 5), 1400, 3.5, 3.5)
softbox('Fill', (5, -6, 0.5), 450, 4, 4)
softbox('Left strip', (-6, -1.5, 0), 650, 0.45, 7)
softbox('Right strip', (6, -1.5, 0), 650, 0.45, 7)
softbox('Top strip', (0, -2.5, 6.5), 500, 7, 0.45)
softbox('Front strip', (-2.4, -7, 0.5), 260, 0.6, 6)
softbox('Rim', (0, 6, 3), 600, 5, 1.2)

camera = bpy.data.objects.new('Front camera, landscape', bpy.data.cameras.new('Front camera'))
scene.collection.objects.link(camera)
camera.data.type = 'ORTHO'
camera.data.ortho_scale = ORTHO_SCALE
camera.data.clip_end = 100
el = math.radians(ELEVATION)
camera.location = TARGET + Vector((0, -math.cos(el), math.sin(el))) * 12
forward = (TARGET - camera.location).normalized()
up = Vector((0, 0, 1))
right = forward.cross(up).normalized()
up = right.cross(forward).normalized()
camera.rotation_euler = Matrix((right, up, -forward)).transposed().to_euler()
scene.camera = camera

# A quarter turn CLOCKWISE as seen by the camera: +90 deg about the viewing
# direction (thumb pointing away from the viewer), through TARGET. The image
# up vector maps onto image right, so the lid edge ends up on the right.
SPIN = Matrix.Translation(TARGET) @ Matrix.Rotation(math.radians(90), 4, forward) @ Matrix.Translation(-TARGET)
assert (SPIN.to_3x3() @ up - right).length < 1e-6
base_pose = {o.name: o.matrix_world.copy() for o in model_roots}


def set_spin(on):
    for o in model_roots:
        o.matrix_world = (SPIN if on else Matrix.Identity(4)) @ base_pose[o.name]
    bpy.context.view_layer.update()


def led_world():
    pts = [led_obj.matrix_world @ v.co for v in led_obj.data.vertices]
    return sum(pts, Vector()) / len(pts)


def silhouette(path):
    image = bpy.data.images.load(str(path), check_existing=False)
    width, height = image.size
    pixels = np.empty(width * height * 4, dtype=np.float32)
    image.pixels.foreach_get(pixels)
    bpy.data.images.remove(image)
    ys, xs = np.nonzero(pixels.reshape(height, width, 4)[:, :, 3] > 0.05)
    cx = (xs.min() + xs.max() + 1) / (2 * width)
    cy = (ys.min() + ys.max() + 1) / (2 * height)
    radius = np.sqrt(((xs + 0.5) / width - cx) ** 2 + ((ys + 0.5) / height - cy) ** 2).max()
    bounds = {'minX': xs.min() / width, 'maxX': (xs.max() + 1) / width,
              'minY': ys.min() / height, 'maxY': (ys.max() + 1) / height}
    return ({'x': float(cx), 'y': float(cy), 'radius': float(radius)},
            {k: float(v) for k, v in bounds.items()})


def render(path, size, samples):
    scene.render.resolution_x = scene.render.resolution_y = size
    scene.cycles.samples = samples
    scene.render.filepath = str(path)
    start = time.time()
    bpy.ops.render.render(write_still=True)
    return time.time() - start


def camera_info():
    return {
        'type': 'orthographic',
        'location': [round(v, 6) for v in camera.location],
        'target': [round(v, 6) for v in TARGET],
        'up': [round(v, 6) for v in up],
        'elevationDegrees': ELEVATION,
        'orthoScale': ORTHO_SCALE,
        'note': 'Shared by case-open, case-closed, case-pointer, lid/* and spin/*; '
                'world units are the USD scene x50, case is 3.10 wide.',
    }


def project(point):
    p = world_to_camera_view(scene, camera, point)
    return {'x': round(p.x, 6), 'y': round(p.y, 6)}


def write_still(name, view, lid_angle, led_level, spun, size, samples):
    set_spin(False)
    set_lid(lid_angle)
    overlaps = lid_bud_overlaps()
    set_spin(spun)
    set_led(led_level)
    path = out / f'{name}.png'
    seconds = render(path, size, samples)
    sil, bounds = silhouette(path)
    metadata = {
        'source': source,
        'sourceSHA256': source_sha,
        'view': view,
        'camera': camera_info(),
        'lidAngleDegrees': lid_angle,
        'statusLight': {'level': led_level, 'color': LED_GREEN, **project(led_world())},
        'rotation': {'degreesClockwiseOnScreen': 90 if spun else 0,
                     'pivot': project(TARGET)},
        'silhouette': sil,
        'silhouetteBounds': bounds,
        'size': [size, size],
        'samples': samples,
        'renderSeconds': round(seconds, 1),
        'lidEarbudTriangleOverlaps': overlaps,
        'device': device,
        'renderer': bpy.app.version_string,
    }
    (out / f'{name}.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(f'Rendered {path} in {seconds:.1f}s, silhouette {sil}, lid/earbud overlaps {overlaps}')
    set_spin(False)


if 'open' in only:
    write_still('case-open', 'front, landscape, lid open (Apple articulation, 115 deg), '
                'earbuds seated, status light off', LID_OPEN, 0.0, False, STILL_SIZE, STILL_SAMPLES)
if 'closed' in only:
    write_still('case-closed', 'front, landscape, lid closed, status light on',
                0.0, 1.0, False, STILL_SIZE, STILL_SAMPLES)
if 'pointer' in only:
    write_still('case-pointer', 'front, closed case turned 90 deg clockwise about the viewing axis '
                '(upright, lid edge on the right), status light on; camera and lights unchanged',
                0.0, 1.0, True, STILL_SIZE, STILL_SAMPLES)

if 'lid' in only:
    frames = []
    for k in range(FRAMES):
        t = k / (FRAMES - 1)
        angle = LID_OPEN * (1 + math.cos(math.pi * t)) / 2     # ease in-out
        led = {FRAMES - 2: 0.5, FRAMES - 1: 1.0}.get(k, 0.0)
        set_spin(False)
        set_lid(angle)
        set_led(led)
        overlaps = lid_bud_overlaps()
        path = out / 'lid' / f'lid-{k:02d}.png'
        seconds = render(path, FRAME_SIZE, FRAME_SAMPLES)
        sil, bounds = silhouette(path)
        frames.append({'file': path.name, 'lidAngleDegrees': round(angle, 3), 'statusLightLevel': led,
                       'silhouette': sil, 'renderSeconds': round(seconds, 1),
                       'lidEarbudTriangleOverlaps': overlaps})
        print(f'Rendered {path} lid {angle:.1f} deg in {seconds:.1f}s, overlaps {overlaps}')
    (out / 'lid' / 'lid.json').write_text(json.dumps({
        'source': source, 'sourceSHA256': source_sha,
        'view': 'front, landscape, lid easing (cosine in-out) from open (00) to closed (11); '
                'status light fades in over the last two frames',
        'camera': camera_info(), 'statusLightColor': LED_GREEN,
        'size': [FRAME_SIZE, FRAME_SIZE], 'samples': FRAME_SAMPLES, 'frames': frames,
        'device': device, 'renderer': bpy.app.version_string,
    }, indent=2) + '\n')

if 'spin' in only:
    # The open case turning about the world's vertical axis through TARGET,
    # camera and lights fixed. Frame 0 is the front view, the same as lid-00.
    set_spin(False)
    set_lid(LID_OPEN)
    set_led(0.0)
    upright = {o.name: o.matrix_world.copy() for o in model_roots}
    frames = []
    for k in range(SPIN_FRAMES):
        degrees = 360 * k / SPIN_FRAMES
        turn = Matrix.Translation(TARGET) @ Matrix.Rotation(math.radians(degrees), 4, 'Z') @ Matrix.Translation(-TARGET)
        for o in model_roots:
            o.matrix_world = turn @ upright[o.name]
        bpy.context.view_layer.update()
        path = out / 'spin' / f'spin-{k:03d}.png'
        seconds = render(path, FRAME_SIZE, FRAME_SAMPLES)
        frames.append({'file': path.name, 'degrees': round(degrees, 3), 'renderSeconds': round(seconds, 1)})
        print(f'Rendered {path} at {degrees:.0f} deg in {seconds:.1f}s')
    for o in model_roots:
        o.matrix_world = upright[o.name]
    bpy.context.view_layer.update()
    (out / 'spin' / 'spin.json').write_text(json.dumps({
        'source': source, 'sourceSHA256': source_sha,
        'view': 'front, landscape, lid open (115 deg), status light off, turning a full turn '
                'about the vertical axis through the case centre; frame 0 matches lid-00',
        'camera': camera_info(), 'size': [FRAME_SIZE, FRAME_SIZE], 'samples': FRAME_SAMPLES,
        'framesPerSecond': 30, 'frames': frames,
        'device': device, 'renderer': bpy.app.version_string,
    }, indent=2) + '\n')

# --------------------------------------------------------------- review ----
if 'review' in only:
    import OpenImageIO as oiio

    def read(path):
        inp = oiio.ImageInput.open(str(path))
        pixels = inp.read_image(0, 0, 0, 4, 'uint8')
        inp.close()
        return pixels.astype(np.float32) / 255

    def write(path, rgb):
        rgb = (np.clip(rgb, 0, 1) * 255 + 0.5).astype(np.uint8)
        o = oiio.ImageOutput.create(str(path))
        o.open(str(path), oiio.ImageSpec(rgb.shape[1], rgb.shape[0], 3, 'uint8'))
        o.write_image(rgb)
        o.close()

    def over(rgba, hex_color):
        bg = np.array([int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5)], dtype=np.float32)
        a = rgba[:, :, 3:4]
        return rgba[:, :, :3] * a + bg * (1 - a)

    stages = ('#EFEFF2', '#2A2A2D')
    for name in ('case-open', 'case-closed', 'case-pointer'):
        if (out / f'{name}.png').exists():
            img = read(out / f'{name}.png')
            write(out / 'review' / f'{name}-stages.png', np.hstack([over(img, s) for s in stages]))
    lid_files = sorted((out / 'lid').glob('lid-*.png'))
    if lid_files:
        rows = []
        for s in stages:
            tiles = []
            for f in lid_files:
                rgb = over(read(f), s)
                h, w = rgb.shape[:2]
                tiles.append(rgb[:h // 2 * 2, :w // 2 * 2].reshape(h // 2, 2, w // 2, 2, 3).mean((1, 3)))
            rows.append(np.hstack(tiles))
        write(out / 'review' / 'lid-strip.png', np.vstack(rows))
    print('Wrote review composites to', out / 'review')
