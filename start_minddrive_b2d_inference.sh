#!/usr/bin/env bash
set -euo pipefail

# MindDrive closed-loop inference launcher for Bench2Drive.
# Usage:
#   bash start_minddrive_b2d_inference.sh
# Optional overrides:
#   BASE_ROUTES=/path/to/routes_no_suffix_or_xml \
#   CHECKPOINT_PATH=/path/to/save/result.json \
#   SAVE_PATH=/path/to/save/sensor_data \
#   GPU_RANK=0 REPETITIONS=1 ROUTES_SUBSET="" \
#   bash start_minddrive_b2d_inference.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ------------------------- User-configurable defaults -------------------------
CARLA_ROOT="${CARLA_ROOT:-/home/czf/workspace/carla}"

# You can point this to a Bench2Drive routes xml in another workspace.
# If BASE_ROUTES has no .xml suffix, the script appends .xml automatically.
BASE_ROUTES="${BASE_ROUTES:-/home/czf/workspace/Bench2Drive-VL/leaderboard/data/drivetransformer_bench2drive_dev10}"

TEAM_AGENT="${TEAM_AGENT:-$SCRIPT_DIR/team_code/minddrive_b2d_agent.py}"
CONFIG_PATH="${CONFIG_PATH:-$SCRIPT_DIR/adzoo/minddrive/configs/minddrive_qwen2_05B_infer.py}"
MODEL_CKPT="${MODEL_CKPT:-$SCRIPT_DIR/ckpts/minddrive_rltrain.pth}"
LLM_DIR="${LLM_DIR:-$SCRIPT_DIR/ckpts/llava-qwen2-0.5b}"
BENCH2DRIVE_ZOO_ROOT="${BENCH2DRIVE_ZOO_ROOT:-/home/czf/Disk/CZF/Bench2DriveZoo}"
LEADERBOARD_ROOT="${LEADERBOARD_ROOT:-/home/czf/workspace/Bench2Drive-VL/leaderboard}"
PYTHON_BIN="${PYTHON_BIN:-/home/czf/anaconda3/envs/MindDrive/bin/python}"
B2D_SHIM_ROOT="${B2D_SHIM_ROOT:-$SCRIPT_DIR/outputs/py_shims}"

CHECKPOINT_PATH="${CHECKPOINT_PATH:-$SCRIPT_DIR/outputs/closed_loop_checkpoint.json}"
DEBUG_CHECKPOINT_PATH="${DEBUG_CHECKPOINT_PATH:-$SCRIPT_DIR/outputs/closed_loop_live.txt}"
SAVE_PATH="${SAVE_PATH:-$SCRIPT_DIR/outputs/closed_loop_sensor}"

HOST="${HOST:-localhost}"
PORT="${PORT:-2000}"
TM_PORT="${TM_PORT:-8000}"
GPU_RANK="${GPU_RANK:-0}"
REPETITIONS="${REPETITIONS:-1}"
ROUTES_SUBSET="${ROUTES_SUBSET:-}"
LOAD_ONCE="${LOAD_ONCE:-1}"
IS_BENCH2DRIVE="${IS_BENCH2DRIVE:-1}"
# -----------------------------------------------------------------------------

mkdir -p "$(dirname "$CHECKPOINT_PATH")" "$SAVE_PATH"

if [[ "$BASE_ROUTES" == *.xml ]]; then
  ROUTES="$BASE_ROUTES"
else
  ROUTES="${BASE_ROUTES}.xml"
fi

if [[ ! -f "$ROUTES" ]]; then
  echo "[ERROR] Routes file not found: $ROUTES"
  echo "        Set BASE_ROUTES to your Bench2Drive route xml (with or without .xml)."
  exit 1
fi

if [[ ! -f "$TEAM_AGENT" ]]; then
  echo "[ERROR] Agent file not found: $TEAM_AGENT"
  exit 1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "[ERROR] Config file not found: $CONFIG_PATH"
  exit 1
fi

if [[ ! -f "$MODEL_CKPT" ]]; then
  echo "[ERROR] Model checkpoint not found: $MODEL_CKPT"
  exit 1
fi

if [[ ! -d "$CARLA_ROOT" ]]; then
  echo "[ERROR] CARLA_ROOT does not exist: $CARLA_ROOT"
  exit 1
fi

if [[ ! -d "$BENCH2DRIVE_ZOO_ROOT" ]]; then
  echo "[ERROR] BENCH2DRIVE_ZOO_ROOT does not exist: $BENCH2DRIVE_ZOO_ROOT"
  echo "        Set BENCH2DRIVE_ZOO_ROOT to your Bench2DriveZoo folder."
  exit 1
fi

if [[ ! -d "$LEADERBOARD_ROOT" ]]; then
  echo "[ERROR] LEADERBOARD_ROOT does not exist: $LEADERBOARD_ROOT"
  echo "        Set LEADERBOARD_ROOT to your Bench2Drive leaderboard folder."
  exit 1
fi

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "[ERROR] PYTHON_BIN does not exist or is not executable: $PYTHON_BIN"
  echo "        Set PYTHON_BIN to your MindDrive env python path."
  exit 1
fi

# Ensure llm directory exists.
if [[ ! -d "$LLM_DIR" ]]; then
  echo "[ERROR] Missing llm directory: $LLM_DIR"
  echo "        Download 0.5B base model into ckpts or set LLM_DIR explicitly."
  exit 1
fi

# leaderboard_evaluator.py reads weather.xml from relative path leaderboard/data/weather.xml.
# If local file is missing, link it from external Bench2Drive leaderboard assets.
LOCAL_WEATHER="$SCRIPT_DIR/leaderboard/data/weather.xml"
EXTERNAL_WEATHER="$LEADERBOARD_ROOT/data/weather.xml"
if [[ ! -f "$LOCAL_WEATHER" ]]; then
  if [[ ! -f "$EXTERNAL_WEATHER" ]]; then
    echo "[ERROR] Missing weather.xml in both locations:"
    echo "        local:    $LOCAL_WEATHER"
    echo "        external: $EXTERNAL_WEATHER"
    exit 1
  fi
  mkdir -p "$SCRIPT_DIR/leaderboard/data"
  ln -sfn "$EXTERNAL_WEATHER" "$LOCAL_WEATHER"
fi

# ------------------------------- Environment ---------------------------------
export CARLA_ROOT
export CARLA_SERVER="$CARLA_ROOT/CarlaUE4.sh"
export SCENARIO_RUNNER_ROOT="$SCRIPT_DIR/rl_projects/scenario_runner"
export SCRIPT_DIR
export BENCH2DRIVE_ZOO_ROOT
export IS_BENCH2DRIVE
export SAVE_PATH
BENCH2DRIVE_ZOO_PARENT="$(dirname "$BENCH2DRIVE_ZOO_ROOT")"

# Runtime shim: keep using external Bench2DriveZoo, but override planner import
# to MindDrive local implementation whose RoutePlanner.run_step return format
# matches minddrive_b2d_agent expectations.
mkdir -p "$B2D_SHIM_ROOT/Bench2DriveZoo/team_code"
cat > "$B2D_SHIM_ROOT/Bench2DriveZoo/__init__.py" << 'PY'
import os
_external = os.environ.get("BENCH2DRIVE_ZOO_ROOT")
if _external and os.path.isdir(_external) and _external not in __path__:
  __path__.append(_external)
PY
cat > "$B2D_SHIM_ROOT/Bench2DriveZoo/team_code/__init__.py" << 'PY'
import os
_root = os.environ.get("BENCH2DRIVE_ZOO_ROOT")
_external_team_code = os.path.join(_root, "team_code") if _root else ""
if _external_team_code and os.path.isdir(_external_team_code) and _external_team_code not in __path__:
  __path__.append(_external_team_code)
PY
cat > "$B2D_SHIM_ROOT/Bench2DriveZoo/team_code/planner.py" << 'PY'
from team_code.planner import *
PY
cat > "$B2D_SHIM_ROOT/Bench2DriveZoo/team_code/pid_controller_de.py" << 'PY'
from team_code.pid_controller_de import *
PY

# Runtime shim: unify srunner imports with rl_projects namespace to avoid
# duplicate CarlaDataProvider singletons (world initialized in one module path,
# read from another path).
mkdir -p "$B2D_SHIM_ROOT/srunner/scenariomanager"
cat > "$B2D_SHIM_ROOT/srunner/__init__.py" << 'PY'
import os
_sr_root = os.environ.get("SCENARIO_RUNNER_ROOT")
_external = os.path.join(_sr_root, "srunner") if _sr_root else ""
if _external and os.path.isdir(_external) and _external not in __path__:
  __path__.append(_external)
PY
cat > "$B2D_SHIM_ROOT/srunner/scenariomanager/__init__.py" << 'PY'
import os
_sr_root = os.environ.get("SCENARIO_RUNNER_ROOT")
_external = os.path.join(_sr_root, "srunner", "scenariomanager") if _sr_root else ""
if _external and os.path.isdir(_external) and _external not in __path__:
  __path__.append(_external)
PY
cat > "$B2D_SHIM_ROOT/srunner/scenariomanager/carla_data_provider.py" << 'PY'
from rl_projects.scenario_runner.srunner.scenariomanager.carla_data_provider import *
PY
cat > "$B2D_SHIM_ROOT/srunner/scenariomanager/watchdog.py" << 'PY'
from rl_projects.scenario_runner.srunner.scenariomanager.watchdog import *
PY

# Runtime shim: align rl_projects.leaderboard Track enum with leaderboard Track enum.
# This avoids false "wrong track" errors caused by comparing enums from different module paths.
mkdir -p "$B2D_SHIM_ROOT/rl_projects/leaderboard/autoagents"
cat > "$B2D_SHIM_ROOT/rl_projects/__init__.py" << 'PY'
import os
_repo_root = os.environ.get("SCRIPT_DIR")
_external = os.path.join(_repo_root, "rl_projects") if _repo_root else ""
if _external and os.path.isdir(_external) and _external not in __path__:
  __path__.append(_external)
PY
cat > "$B2D_SHIM_ROOT/rl_projects/leaderboard/__init__.py" << 'PY'
import os
_repo_root = os.environ.get("SCRIPT_DIR")
_external = os.path.join(_repo_root, "rl_projects", "leaderboard") if _repo_root else ""
if _external and os.path.isdir(_external) and _external not in __path__:
  __path__.append(_external)
PY
cat > "$B2D_SHIM_ROOT/rl_projects/leaderboard/autoagents/__init__.py" << 'PY'
import os
_repo_root = os.environ.get("SCRIPT_DIR")
_external = os.path.join(_repo_root, "rl_projects", "leaderboard", "autoagents") if _repo_root else ""
if _external and os.path.isdir(_external) and _external not in __path__:
  __path__.append(_external)
PY
cat > "$B2D_SHIM_ROOT/rl_projects/leaderboard/autoagents/autonomous_agent.py" << 'PY'
from leaderboard.autoagents.autonomous_agent import *
PY

# Runtime hotfix: some leaderboard paths expect ScenarioManager.route_scenario
# during result writing, but only self.scenario is set in load_scenario().
# Patch at interpreter startup without modifying project source files.
cat > "$B2D_SHIM_ROOT/sitecustomize.py" << 'PY'
try:
  import importlib

  def _patch_sm(module_name):
    try:
      _sm = importlib.import_module(module_name)
      _orig_load = _sm.ScenarioManager.load_scenario
      def _patched_load(self, scenario, agent, route_index, rep_number):
        _orig_load(self, scenario, agent, route_index, rep_number)
        self.route_scenario = scenario
      _sm.ScenarioManager.load_scenario = _patched_load

      _orig_my_load = _sm.ScenarioManager.my_load_scenario
      def _patched_my_load(self, scenario, ego_vehicles, route_index, rep_number):
        _orig_my_load(self, scenario, ego_vehicles, route_index, rep_number)
        self.route_scenario = scenario
      _sm.ScenarioManager.my_load_scenario = _patched_my_load
    except Exception:
      pass

  _patch_sm('leaderboard.scenarios.scenario_manager')
  _patch_sm('rl_projects.leaderboard.scenarios.scenario_manager')
except Exception:
  pass
PY

export PYTHONPATH="$B2D_SHIM_ROOT:$SCRIPT_DIR:$SCRIPT_DIR/rl_projects:$SCENARIO_RUNNER_ROOT:$BENCH2DRIVE_ZOO_PARENT:$BENCH2DRIVE_ZOO_ROOT:${PYTHONPATH:-}"

if compgen -G "$CARLA_ROOT/PythonAPI/carla/dist/carla-*.egg" > /dev/null; then
  PY_VER="$($PYTHON_BIN -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  PY_MAJOR="$($PYTHON_BIN -c 'import sys; print(sys.version_info.major)')"
  CARLA_EGG=""

  # Prefer the exact interpreter version (for example: py3.8), then any same major version (py3),
  # and only as a final fallback use the first available egg.
  if compgen -G "$CARLA_ROOT/PythonAPI/carla/dist/carla-*-py${PY_VER}-*.egg" > /dev/null; then
    CARLA_EGG="$(ls "$CARLA_ROOT"/PythonAPI/carla/dist/carla-*-py${PY_VER}-*.egg | head -n 1)"
  elif compgen -G "$CARLA_ROOT/PythonAPI/carla/dist/carla-*-py${PY_MAJOR}.*-*.egg" > /dev/null; then
    CARLA_EGG="$(ls "$CARLA_ROOT"/PythonAPI/carla/dist/carla-*-py${PY_MAJOR}.*-*.egg | head -n 1)"
  elif compgen -G "$CARLA_ROOT/PythonAPI/carla/dist/carla-*-py${PY_MAJOR}-*.egg" > /dev/null; then
    CARLA_EGG="$(ls "$CARLA_ROOT"/PythonAPI/carla/dist/carla-*-py${PY_MAJOR}-*.egg | head -n 1)"
  else
    CARLA_EGG="$(ls "$CARLA_ROOT"/PythonAPI/carla/dist/carla-*.egg | head -n 1)"
  fi

  export PYTHONPATH="$CARLA_ROOT/PythonAPI:$CARLA_ROOT/PythonAPI/carla:$CARLA_EGG:$PYTHONPATH"
else
  export PYTHONPATH="$CARLA_ROOT/PythonAPI:$CARLA_ROOT/PythonAPI/carla:$PYTHONPATH"
fi

AGENT_CONFIG="${CONFIG_PATH}+${MODEL_CKPT}"

echo "================ MindDrive Closed-Loop Inference ================"
echo "CARLA_ROOT:         $CARLA_ROOT"
echo "ROUTES:             $ROUTES"
echo "TEAM_AGENT:         $TEAM_AGENT"
echo "AGENT_CONFIG:       $AGENT_CONFIG"
echo "LLM_DIR:            $LLM_DIR"
echo "B2D_ZOO_ROOT:       $BENCH2DRIVE_ZOO_ROOT"
echo "LEADERBOARD_ROOT:   $LEADERBOARD_ROOT"
echo "B2D_SHIM_ROOT:      $B2D_SHIM_ROOT"
echo "PYTHON_BIN:         $PYTHON_BIN"
echo "CHECKPOINT_PATH:    $CHECKPOINT_PATH"
echo "DEBUG_CHECKPOINT:   $DEBUG_CHECKPOINT_PATH"
echo "SAVE_PATH:          $SAVE_PATH"
echo "GPU_RANK:           $GPU_RANK"
echo "REPETITIONS:        $REPETITIONS"
echo "ROUTES_SUBSET:      ${ROUTES_SUBSET:-<all>}"
echo "LOAD_ONCE:          $LOAD_ONCE"
echo "IS_BENCH2DRIVE:     $IS_BENCH2DRIVE"
echo "================================================================="

"$PYTHON_BIN" "$SCRIPT_DIR/rl_projects/leaderboard/leaderboard_evaluator.py" \
  --host "$HOST" \
  --port "$PORT" \
  --traffic-manager-port "$TM_PORT" \
  --routes "$ROUTES" \
  --routes-subset "$ROUTES_SUBSET" \
  --repetitions "$REPETITIONS" \
  --agent "$TEAM_AGENT" \
  --agent-config "$AGENT_CONFIG" \
  --checkpoint "$CHECKPOINT_PATH" \
  --debug-checkpoint "$DEBUG_CHECKPOINT_PATH" \
  --gpu-rank "$GPU_RANK" \
  --load-once "$LOAD_ONCE"
