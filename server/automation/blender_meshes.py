"""Executed by Blender in a disposable project snapshot."""
import json
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def inspect_asset(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(path))
    objects = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    points = [obj.matrix_world @ Vector(point) for obj in objects for point in obj.bound_box]
    meshes = {obj.data for obj in objects}
    for mesh in meshes:
        mesh.calc_loop_triangles()
    return {
        "path": str(path.relative_to("/job/source")), "meshObjects": len(objects), "uniqueMeshes": len(meshes),
        "vertices": sum(len(mesh.vertices) for mesh in meshes),
        "triangles": sum(len(mesh.loop_triangles) for mesh in meshes),
        "meshesWithoutUV": sum(not mesh.uv_layers for mesh in meshes),
        "materials": len({material for mesh in meshes for material in mesh.materials if material}),
        "bounds": {"min": [min(point[i] for point in points) for i in range(3)],
                   "max": [max(point[i] for point in points) for i in range(3)]} if points else None,
    }


output, *assets = sys.argv[sys.argv.index("--") + 1:]
report = {"assets": [], "errors": []}
for asset in map(Path, assets):
    try:
        result = inspect_asset(asset)
        report["assets"].append(result)
        if not result["meshObjects"]:
            report["errors"].append({"path": result["path"], "message": "Asset contains no mesh objects"})
    except (RuntimeError, ValueError, OSError) as error:
        report["errors"].append({"path": str(asset.relative_to("/job/source")), "message": str(error)[:500]})
Path(output).write_text(json.dumps(report, allow_nan=False))
