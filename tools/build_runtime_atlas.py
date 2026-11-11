"""Build the production atlas from checked-in V3 frames and V2 ground assets.

Run from any directory. Requires Pillow; never modifies source art.
"""
from __future__ import annotations
import hashlib
import json
import math
import shutil
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets/art/v3"
OUTPUT = ROOT / "game/assets"
PADDING = 1
FRAME_SIZE = 40
COLUMNS = 48


def build() -> None:
    manifest_path = SOURCE / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert manifest["canvas_px"] == [FRAME_SIZE, FRAME_SIZE]
    assert manifest["pixel_filter"] == "nearest"
    pitch = FRAME_SIZE + 2 * PADDING
    height = math.ceil(manifest["total_frames"] / COLUMNS) * pitch
    atlas = Image.new("RGBA", (COLUMNS * pitch, height))
    clips = []
    action_names = []
    frame_index = 0
    source_digest = hashlib.sha256(manifest_path.read_bytes())
    for species in manifest["species"]:
        for action in species["actions"]:
            action_name = f'{species["id"]}/{action["id"]}'
            action_names.append(action_name)
            durations = action["durations_ms"]
            assert len(durations) == action["frame_count"]
            assert all(duration > 0 for duration in durations)
            for direction in manifest["directions"]:
                rectangles = []
                for index in range(action["frame_count"]):
                    source = SOURCE / "png" / species["id"] / action["id"] / direction / f"{index:03}.png"
                    source_digest.update(source.read_bytes())
                    with Image.open(source) as image:
                        assert image.size == (FRAME_SIZE, FRAME_SIZE), source
                        image = image.convert("RGBA")
                        x = frame_index % COLUMNS * pitch + PADDING
                        y = frame_index // COLUMNS * pitch + PADDING
                        # Transparent padding keeps neighboring cells out of nearest sampling.
                        atlas.paste(image, (x, y))
                    rectangles.append([x, y, FRAME_SIZE, FRAME_SIZE])
                    frame_index += 1
                clips.append({
                    "action": action_name,
                    "direction": direction,
                    "pivot": species["pivots_by_direction"][direction],
                    "loop": action["loop"],
                    "phase_randomization": action.get("phase_randomization", False),
                    "durations_ms": durations,
                    "rectangles": rectangles,
                })
    assert frame_index == manifest["total_frames"] == 1328
    assert len(clips) == manifest["total_clips"] == 184
    assert len(action_names) == manifest["total_actions"] == 23
    OUTPUT.mkdir(parents=True, exist_ok=True)
    atlas.save(OUTPUT / "animals.png", optimize=True)
    metadata = {
        "schema_version": 1,
        "source_revision": manifest["revision"],
        "source_sha256": source_digest.hexdigest(),
        "atlas": "res://assets/animals.png",
        "atlas_size": list(atlas.size),
        "padding": PADDING,
        "filter": "nearest",
        "mipmaps": False,
        "trimmed": False,
        "rotated": False,
        "actions": action_names,
        "directions": manifest["directions"],
        "frame_count": frame_index,
        "clips": clips,
    }
    (OUTPUT / "animals.json").write_text(json.dumps(metadata, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    for name in ("grass_tile", "grass_grazed_tile", "shadow_ellipse"):
        shutil.copyfile(ROOT / "assets/art/v2/png" / f"{name}.png", OUTPUT / f"{name}.png")
    print(f"Built {len(clips)} clips / {frame_index} frames, {atlas.width}x{atlas.height}, padding={PADDING}; source sha256={source_digest.hexdigest()}")


if __name__ == "__main__":
    build()
