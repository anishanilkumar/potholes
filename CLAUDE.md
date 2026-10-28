# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

End-to-end AI pipeline that processes dashcam videos, extracts GPS telemetry via OCR, classifies road condition per frame using a fine-tuned ViT/EfficientNet/Swin classifier, and renders an interactive map of road quality snapped to OpenStreetMap road segments. A separate YOLOv8 branch detects individual potholes in video.

## Environment Setup

Python 3.11 (`uv` is the package manager). System dependencies: `ffmpeg` and `tesseract`.

```bash
source aliases.sh        # loads project aliases
install-deps             # installs all Python deps via uv pip
```

The `pyproject.toml` lists only the `road_classifier/` Flask app's auth dependencies; ML/CV dependencies are managed manually via `uv pip` (see `aliases.sh`).

## Source Layout

```
src/
  ingestion/     # Video → frames (FFmpeg) and OCR telemetry extraction
  annotation/    # Label Studio integration: sampling, pre-annotation, sync
  classifier/    # Train / evaluate / run inference with the road condition classifier
  mapping/       # Classify frames at scale, snap GPS to OSM, render HTML map
  yolo/          # Train / infer pothole detector (YOLOv8)
  dataset/       # Dataset utilities: consensus export, augmentation, user management
  evaluation/    # Thesis/evaluation sample generation

road_classifier/ # Standalone Flask web app for collaborative human labelling
models/          # Saved .pth (classifier) and .pt (YOLO) weights
dataset/         # Annotation batches, YOLO training splits
processed_data/  # Pipeline outputs (frames, CSVs, map files, hyperparam results)
config.yaml      # Camera-specific OCR ROI coordinates and regexes
```

## Pipeline: Road Quality Map

Run these steps in order; each is incremental (skips already-processed files):

```bash
# 1. Extract 1 fps from videos in videos/
python src/ingestion/extract_frames.py -i videos -o processed_data/frames

# 2. OCR telemetry from frames → CSV
python src/ingestion/ocr_processor.py -i processed_data/frames -o processed_data/route_data

# 3. Combine OCRd CSVs and filter (idle, nighttime, GPS outliers)
python src/ingestion/process_frames.py

# 4. Run classifier over all filtered frames, join with GPS
python src/mapping/classify_dataset.py \
    --weights models/<best>.pth \
    --conf-threshold 0.70 --drop-invalid \
    --output processed_data/mapping/predictions.csv

# 5. Snap GPS predictions to OSM road network, aggregate per segment
python src/mapping/snap_to_roads.py \
    --predictions processed_data/mapping/predictions.csv

# 6. Render interactive HTML map
python src/mapping/render_map.py \
    --input processed_data/mapping/road_quality.gpkg \
    --output processed_data/mapping/road_quality_map.html
```

## Pipeline: Road Classifier (Active Learning Loop)

```bash
# Export consensus labels from road_classifier DB → ImageFolder structure
python src/dataset/export_consensus_dataset.py --db road_classifier/classifications.db

# (Optional) augment minority classes
python src/dataset/augment_minority_classes.py

# Train classifier (timm backbone, MPS-accelerated on Mac)
python src/classifier/train_classifier.py \
    --model swin_small_patch4_window7_224 \
    --epochs 50 --freeze-epochs 5 --scheduler cosine \
    --merge-classes   # Excellent/Good→Good, Fair/Poor→Bad

# Evaluate on held-out set
python src/classifier/evaluate_production.py --weights models/<best>.pth

# Sample frames for next active learning round, pre-annotate, import corrections
python src/classifier/sample_active_learning.py
```

## Pipeline: YOLOv8 Pothole Detector

```bash
# Sample unannotated frames for annotation
python src/annotation/sample_frames.py -i processed_data/filtered_frames -o dataset -n 150

# Auto-annotate with current best model for Label Studio
python src/annotation/generate_label_studio_tasks.py --weights models/best_pothole.pt

# After manual correction in Label Studio, sync export
python src/annotation/sync_label_studio_export.py -z ~/Downloads/export.zip

# Train
python src/yolo/train_yolo.py --data-dir dataset --epochs 50

# Video inference
python src/yolo/predict_video.py -v videos/YOUR_VIDEO.MP4
```

## Road Classifier Web App

Standalone collaborative labelling tool at `road_classifier/app.py`. Run with `python road_classifier/app.py`. Classifications are written to `road_classifier/classifications.db`; export via `/api/export`.

Labels: **Excellent / Good / Fair / Poor / Invalid** (keyboard: Q/W/E/R/Space).

## Key Design Decisions

- **config.yaml** maps contributor names to their dashcam's OCR region-of-interest coordinates and regexes — add new contributors here when onboarding a new camera model.
- **Pessimistic vs majority aggregation** in `snap_to_roads.py`: both are stored in the `.gpkg` so `render_map.py` can toggle between them. Majority is the default visible layer; pessimistic is available via the layer control.
- **Class labels**: the classifier supports both a 5-class model (Excellent/Good/Fair/Poor/Invalid) and a merged 3-class model (Good/Bad/Invalid via `--merge-classes`). Ensure the same scheme is used consistently between training, inference, and map rendering.
- **Group-aware train/val split** in `train_classifier.py` uses `GroupShuffleSplit` on video identity to prevent frames from the same video appearing in both train and val.
- **Models saved as `<arch>_best.pth`** in `models/`; YOLO weights are `.pt` files.
