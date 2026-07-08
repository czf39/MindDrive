# =========================
# MindDrive 官方 Bench2Drive 闭环评测（0.5B）
# =========================
set -e

# 1) 基础环境
export CARLA_ROOT=/home/czf/workspace/carla
export IS_BENCH2DRIVE=1
export SAVE_PATH=/home/czf/workspace/MindDrive/outputs/closed_loop_sensor
export ROUTES_FILE=${ROUTES_FILE:-/home/czf/Disk/Code/Bench2Drive/leaderboard/data/drivetransformer_bench2drive_dev10.xml}
mkdir -p /home/czf/workspace/MindDrive/outputs "$SAVE_PATH"

# 2) 运行时 shim（修复两个常见兼容问题）
# 2.1 缺失 Bench2DriveZoo.team_code.pid_controller_de
mkdir -p /tmp/md_shim/Bench2DriveZoo/team_code
cat > /tmp/md_shim/Bench2DriveZoo/team_code/pid_controller_de.py << 'PY'
from team_code.pid_controller_de import *
PY
cat > /tmp/md_shim/Bench2DriveZoo/team_code/planner.py << 'PY'
from team_code.planner import *
PY

# 2.2 统一 srunner 路径，避免 CarlaDataProvider 的 world 未初始化冲突
mkdir -p /tmp/md_shim/srunner/scenariomanager
cat > /tmp/md_shim/srunner/scenariomanager/carla_data_provider.py << 'PY'
from rl_projects.scenario_runner.srunner.scenariomanager.carla_data_provider import *
PY
cat > /tmp/md_shim/srunner/scenariomanager/watchdog.py << 'PY'
from rl_projects.scenario_runner.srunner.scenariomanager.watchdog import *
PY

# 2.3 通过 sitecustomize 强制模块别名，确保 evaluator 与 scenario 使用同一 CarlaDataProvider 模块对象
cat > /tmp/md_shim/sitecustomize.py << 'PY'
import importlib
import sys
import subprocess

base_pkg = importlib.import_module("rl_projects.scenario_runner.srunner")
sm_pkg = importlib.import_module("rl_projects.scenario_runner.srunner.scenariomanager")
cdp_mod = importlib.import_module("rl_projects.scenario_runner.srunner.scenariomanager.carla_data_provider")
wd_mod = importlib.import_module("rl_projects.scenario_runner.srunner.scenariomanager.watchdog")

sys.modules.setdefault("srunner", base_pkg)
sys.modules.setdefault("srunner.scenariomanager", sm_pkg)
sys.modules["srunner.scenariomanager.carla_data_provider"] = cdp_mod
sys.modules["srunner.scenariomanager.watchdog"] = wd_mod

# Unify leaderboard module identities to avoid enum/type mismatch
# between `leaderboard.*` and `rl_projects.leaderboard.*` import paths.
lb_env = importlib.import_module("leaderboard.envs.sensor_interface")
lb_agent = importlib.import_module("leaderboard.autoagents.autonomous_agent")

sys.modules["rl_projects.leaderboard.envs.sensor_interface"] = lb_env
sys.modules["rl_projects.leaderboard.autoagents.autonomous_agent"] = lb_agent

# Ensure ScenarioManager always has route_scenario for result writer.
def _patch_scenario_manager(module_name):
  mod = importlib.import_module(module_name)
  cls = mod.ScenarioManager

  orig_load = cls.load_scenario
  def patched_load(self, scenario, agent, route_index, rep_number):
    orig_load(self, scenario, agent, route_index, rep_number)
    self.route_scenario = scenario
  cls.load_scenario = patched_load

  if hasattr(cls, "my_load_scenario"):
    orig_my_load = cls.my_load_scenario
    def patched_my_load(self, scenario, ego_vehicles, route_index, rep_number):
      orig_my_load(self, scenario, ego_vehicles, route_index, rep_number)
      self.route_scenario = scenario
    cls.my_load_scenario = patched_my_load

  return mod

sm_mod_lb = _patch_scenario_manager("leaderboard.scenarios.scenario_manager")
sm_mod_rl = _patch_scenario_manager("rl_projects.leaderboard.scenarios.scenario_manager")
sys.modules["leaderboard.scenarios.scenario_manager"] = sm_mod_lb
sys.modules["rl_projects.leaderboard.scenarios.scenario_manager"] = sm_mod_lb

# Fix evaluator cleanup command that uses grep pattern starting with '-'.
_orig_popen = subprocess.Popen
def _patched_popen(*args, **kwargs):
  if args and isinstance(args[0], str):
    cmd = args[0]
    bad = "grep '-graphicsadapter="
    if bad in cmd:
      cmd = cmd.replace(bad, "grep -- '-graphicsadapter=")
      args = (cmd,) + args[1:]
  return _orig_popen(*args, **kwargs)
subprocess.Popen = _patched_popen

# Result writer in this codebase may receive ScenarioManager directly
# (without nested `manager` attribute). Make title rendering robust.
rw_mod = importlib.import_module("rl_projects.leaderboard.utils.result_writer")
_orig_create_output_text = rw_mod.ResultOutputProvider.create_output_text
def _patched_create_output_text(self):
  if hasattr(self._data, "manager"):
    return _orig_create_output_text(self)

  output = "\n"
  scenario_name = getattr(getattr(self._data, "scenario_tree", None), "name", "Scenario")
  rep_no = getattr(self._data, "repetition_number", 0)
  output += "\033[1m========= Results of {} (repetition {}) ------ {} \033[1m=========\033[0m\n".format(
    scenario_name, rep_no, self._global_result)
  output += "\n"

  system_time = round(self._data.scenario_duration_system, 2)
  game_time = round(self._data.scenario_duration_game, 2)
  ratio = round(self._data.scenario_duration_game / self._data.scenario_duration_system, 3) if self._data.scenario_duration_system else 0.0
  output += f"System Time: {system_time}s\\n"
  output += f"Game Time: {game_time}s\\n"
  output += f"Ratio (Game/System): {ratio}\\n"
  return output
rw_mod.ResultOutputProvider.create_output_text = _patched_create_output_text
PY

# 3) PYTHONPATH（把 shim 放最前）
export PYTHONPATH=/tmp/md_shim:/home/czf/workspace/MindDrive:/home/czf/workspace/MindDrive/rl_projects:/home/czf/workspace/MindDrive/rl_projects/scenario_runner:/home/czf/Disk/CZF:${PYTHONPATH:-}
export PYTHONPATH=$CARLA_ROOT/PythonAPI:$CARLA_ROOT/PythonAPI/carla:$PYTHONPATH
CARLA_EGG=""
if [ -f "$CARLA_ROOT/PythonAPI/carla/dist/carla-0.9.15-py3.7-linux-x86_64.egg" ]; then
  CARLA_EGG="$CARLA_ROOT/PythonAPI/carla/dist/carla-0.9.15-py3.7-linux-x86_64.egg"
fi
if [ -z "$CARLA_EGG" ]; then
  echo "[ERROR] Missing py3 CARLA egg: $CARLA_ROOT/PythonAPI/carla/dist/carla-0.9.15-py3.7-linux-x86_64.egg"
  echo "        Refuse to use py2.7 egg because current env is Python 3.x"
  exit 1
fi
export PYTHONPATH="$CARLA_EGG:$PYTHONPATH"

# 3.1 快速校验：两种导入路径必须指向同一个 CarlaDataProvider 类对象
python - << 'PY'
from srunner.scenariomanager.carla_data_provider import CarlaDataProvider as A
from rl_projects.scenario_runner.srunner.scenariomanager.carla_data_provider import CarlaDataProvider as B
assert A is B, "CarlaDataProvider import mismatch"
print("[shim-check] CarlaDataProvider unified")

from leaderboard.autoagents.autonomous_agent import Track as T1
from rl_projects.leaderboard.autoagents.autonomous_agent import Track as T2
assert T1 is T2, "Track enum import mismatch"
print("[shim-check] Track enum unified")

from Bench2DriveZoo.team_code.planner import RoutePlanner
print("[shim-check] RoutePlanner source:", RoutePlanner.__module__)

from leaderboard.scenarios.scenario_manager import ScenarioManager
assert hasattr(ScenarioManager, "load_scenario")
print("[shim-check] ScenarioManager patch loaded")
PY


# 4 正式跑官方闭环（注意 agent-config 必须是 config+ckpt 两段）
python /home/czf/workspace/MindDrive/rl_projects/leaderboard/leaderboard_evaluator.py \
  --host localhost \
  --port 2000 \
  --traffic-manager-port 8000 \
  --routes "$ROUTES_FILE" \
  --repetitions 1 \
  --agent /home/czf/workspace/MindDrive/team_code/minddrive_b2d_agent.py \
  --agent-config /home/czf/workspace/MindDrive/adzoo/minddrive/configs/minddrive_qwen2_05B_infer.py+/home/czf/workspace/MindDrive/ckpts/minddrive_rltrain.pth \
  --checkpoint /home/czf/workspace/MindDrive/outputs/minddrive_05b_bench2drive220.json \
  --debug-checkpoint /home/czf/workspace/MindDrive/outputs/minddrive_05b_live.txt \
  --gpu-rank 0 \
  --load-once 1