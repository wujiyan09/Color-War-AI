import os
import ctypes

# ==========================================
# 0. 性能与系统环境初始化
# ==========================================
# 提升 Windows 系统定时器精度至 1ms
try:
    ctypes.windll.winmm.timeBeginPeriod(1)
except Exception:
    pass

# 限制单进程线程数，防止多核心线程爆炸及小核抢占
os.environ["OMP_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["VECLIB_MAXIMUM_THREADS"] = "1"
os.environ["NUMEXPR_NUM_THREADS"] = "1"

import sys
import math
import time
import queue
import random
from collections import deque
from contextlib import contextmanager
import multiprocessing as mp
from multiprocessing import Queue, Process, cpu_count

import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader

# 设置 PyTorch 单线程
torch.set_num_threads(1)

# ==========================================
# C 语言底层 stderr 静默重定向器
# ==========================================
@contextmanager
def silence_stderr():
    stderr_fd = sys.stderr.fileno()
    saved_stderr_fd = os.dup(stderr_fd)
    devnull = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(devnull, stderr_fd)
        yield
    finally:
        os.dup2(saved_stderr_fd, stderr_fd)
        os.close(devnull)
        os.close(saved_stderr_fd)

try:
    with silence_stderr():
        import coremltools as ct
    HAS_COREML = True
except Exception:
    HAS_COREML = False

torch.backends.cudnn.benchmark = True

BOARD_SIZE = 12
NUM_PLAYERS = 4

# ==========================================
# 数值安全辅助函数
# ==========================================
def safe_normalize(logits, valid_mask):
    if not np.any(valid_mask):
        return np.ones(len(logits), dtype=np.float32) / len(logits)
    
    logits = np.nan_to_num(logits, nan=0.0, posinf=1e4, neginf=-1e4)
    valid_logits = logits[valid_mask]
    
    logits_stabilized = logits - np.max(valid_logits)
    exp_p = np.exp(logits_stabilized) * valid_mask
    sum_p = np.sum(exp_p)
    
    if sum_p > 1e-8:
        return exp_p / sum_p
    
    return valid_mask.astype(np.float32) / np.sum(valid_mask)

# ==========================================
# 1. 12x12 连锁反应引擎
# ==========================================
class ChainReactionGame:
    def __init__(self, board_size=BOARD_SIZE, num_players=NUM_PLAYERS):
        self.size = board_size
        self.num_players = num_players
        self.neighbors_dict = {}
        for r in range(self.size):
            for c in range(self.size):
                nbs = []
                if r > 0: nbs.append((r - 1, c))
                if r < self.size - 1: nbs.append((r + 1, c))
                if c > 0: nbs.append((r, c - 1))
                if c < self.size - 1: nbs.append((r, c + 1))
                self.neighbors_dict[(r, c)] = nbs

    def get_initial_board(self):
        return np.full((self.size, self.size, 2), fill_value=[-1, 0], dtype=np.int8)

    def get_valid_moves(self, board, player, total_moves=0):
        if total_moves >= self.num_players:
            if not np.any(board[:, :, 0] == player):
                return []
        valid = []
        for r in range(self.size):
            for c in range(self.size):
                owner = board[r, c, 0]
                if owner == -1 or owner == player:
                    valid.append((r, c))
        return valid

    def get_next_player(self, board, current_player, total_moves):
        next_p = (current_player + 1) % self.num_players
        if total_moves >= self.num_players:
            loop_cnt = 0
            while loop_cnt < self.num_players:
                if np.any(board[:, :, 0] == next_p):
                    break
                next_p = (next_p + 1) % self.num_players
                loop_cnt += 1
        return next_p

    def execute_move(self, board, player, action):
        new_board = board.copy()
        r, c = action
        new_board[r, c, 0] = player
        new_board[r, c, 1] += 1

        if new_board[r, c, 1] < 4:
            return new_board

        q = [(r, c)]
        head = 0
        while head < len(q):
            er, ec = q[head]
            head += 1
            if new_board[er, ec, 1] < 4:
                continue

            new_board[er, ec, 1] -= 4
            if new_board[er, ec, 1] == 0:
                new_board[er, ec, 0] = -1

            for nr, nc in self.neighbors_dict[(er, ec)]:
                new_board[nr, nc, 0] = player
                new_board[nr, nc, 1] += 1
                if new_board[nr, nc, 1] >= 4:
                    q.append((nr, nc))

        new_board[:, :, 1] = np.clip(new_board[:, :, 1], 0, 3)
        return new_board

    def check_terminal(self, board, total_moves):
        if total_moves < self.num_players:
            return False, -1

        orb_counts = np.zeros(self.num_players, dtype=np.int32)
        active_players = set()
        
        for r in range(self.size):
            for c in range(self.size):
                owner = board[r, c, 0]
                if owner != -1:
                    active_players.add(owner)
                    orb_counts[owner] += board[r, c, 1]

        if len(active_players) == 1:
            return True, list(active_players)[0]
        elif len(active_players) == 0:
            return True, -1

        total_orbs = np.sum(orb_counts)
        if total_orbs >= 20:
            for p in range(self.num_players):
                if orb_counts[p] / total_orbs >= 0.60:
                    return True, p

        return False, -1

    def board_to_tensor(self, board, current_player):
        """将棋盘转换为以 current_player 为 Channel 0 的相对视角 Tensor"""
        tensor = np.zeros((4, self.size, self.size), dtype=np.float32)
        for i in range(self.num_players):
            rel_p = (current_player + i) % self.num_players
            mask = (board[:, :, 0] == rel_p)
            tensor[i][mask] = board[:, :, 1][mask] / 3.0
        return tensor

# ==========================================
# 2. ResNet 神经网络架构
# ==========================================
class ResBlock(nn.Module):
    def __init__(self, channels):
        super().__init__()
        self.conv1 = nn.Conv2d(channels, channels, kernel_size=3, padding=1)
        self.bn1 = nn.BatchNorm2d(channels)
        self.conv2 = nn.Conv2d(channels, channels, kernel_size=3, padding=1)
        self.bn2 = nn.BatchNorm2d(channels)

    def forward(self, x):
        res = x
        out = torch.relu(self.bn1(self.conv1(x)))
        out = self.bn2(self.conv2(out))
        return torch.relu(out + res)

class ColorWarNet(nn.Module):
    def __init__(self, board_size=12, num_players=4, num_res_blocks=4):
        super().__init__()
        self.board_size = board_size
        self.num_players = num_players
        self.start = nn.Sequential(
            nn.Conv2d(4, 128, kernel_size=3, padding=1),
            nn.BatchNorm2d(128),
            nn.ReLU()
        )
        self.res_blocks = nn.ModuleList([ResBlock(128) for _ in range(num_res_blocks)])
        self.policy_head = nn.Sequential(
            nn.Conv2d(128, 32, kernel_size=1),
            nn.BatchNorm2d(32),
            nn.ReLU(),
            nn.Flatten(),
            nn.Linear(32 * board_size * board_size, board_size * board_size)
        )
        self.value_head = nn.Sequential(
            nn.Conv2d(128, 3, kernel_size=1),
            nn.BatchNorm2d(3),
            nn.ReLU(),
            nn.Flatten(),
            nn.Linear(3 * board_size * board_size, 64),
            nn.ReLU(),
            nn.Linear(64, num_players),
            nn.Tanh()
        )

    def forward(self, x):
        x = self.start(x)
        for block in self.res_blocks:
            x = block(x)
        return self.policy_head(x), self.value_head(x)

# ==========================================
# 3. 数据生成与 Dataset
# ==========================================
def _generate_chunk(num_samples):
    board_size = 12
    num_players = 4
    inputs = np.zeros((num_samples, 4, board_size, board_size), dtype=np.float32)
    policy_targets = np.zeros((num_samples, board_size * board_size), dtype=np.float32)
    value_targets = np.zeros((num_samples, num_players), dtype=np.float32)

    game_tmp = ChainReactionGame(board_size, num_players)

    for i in range(num_samples):
        for r in range(board_size):
            for c in range(board_size):
                if np.random.rand() < 0.35:
                    rel_owner = np.random.randint(0, num_players)
                    count = np.random.randint(1, 4)
                    inputs[i, rel_owner, r, c] = count / 3.0

        scores = np.zeros((board_size, board_size), dtype=np.float32)
        valid_mask = np.zeros((board_size, board_size), dtype=bool)

        for r in range(board_size):
            for c in range(board_size):
                nb_count = len(game_tmp.neighbors_dict[(r, c)])
                cell_owner = -1
                cell_count = 0
                for p in range(num_players):
                    if inputs[i, p, r, c] > 0:
                        cell_owner = p
                        cell_count = int(inputs[i, p, r, c] * 3)

                if cell_owner == -1 or cell_owner == 0:
                    valid_mask[r, c] = True
                    s = 1.0
                    if nb_count == 4: s += 3.0
                    elif nb_count == 3: s += 1.5
                    if cell_count + 1 >= 4: s += 25.0
                    elif cell_count == 2: s += 6.0
                    scores[r, c] = s

        policy_targets[i] = safe_normalize(scores.flatten(), valid_mask.flatten())
        
        total_orbs = np.sum(inputs[i, :, :, :]) + 1e-5
        for p in range(num_players):
            p_orbs = np.sum(inputs[i, p, :, :])
            value_targets[i, p] = np.clip((p_orbs / total_orbs) * 2.0 - 0.5, -1.0, 1.0)

    return inputs, policy_targets, value_targets

def generate_heuristic_data(num_samples=200000):
    n_cores = min(cpu_count(), 12)
    print(f"📦 [Phase 1] 启动 {n_cores} 核心并发生成 {num_samples} 条预训练样本...")
    
    chunk_size = num_samples // n_cores
    chunks = [chunk_size] * n_cores
    chunks[-1] += num_samples % n_cores

    inputs_list, p_targets_list, v_targets_list = [], [], []
    with mp.Pool(processes=n_cores) as pool:
        results = pool.map(_generate_chunk, chunks)
        
    for res in results:
        inputs_list.append(res[0])
        p_targets_list.append(res[1])
        v_targets_list.append(res[2])

    inputs = np.concatenate(inputs_list, axis=0)
    policy_targets = np.concatenate(p_targets_list, axis=0)
    value_targets = np.concatenate(v_targets_list, axis=0)
    
    return torch.tensor(inputs), torch.tensor(policy_targets), torch.tensor(value_targets)

class ReplayBufferDataset(Dataset):
    def __init__(self, buffer_data):
        self.data = buffer_data

    def __len__(self):
        return len(self.data)

    def __getitem__(self, idx):
        s_mat, p_mat, v_vec = self.data[idx]
        k = np.random.randint(0, 4)
        flip = np.random.rand() > 0.5

        s_rot = np.rot90(s_mat, k, axes=(1, 2))
        p_grid = np.rot90(p_mat.reshape(12, 12), k, axes=(0, 1))

        if flip:
            s_rot = np.flip(s_rot, axis=2)
            p_grid = np.flip(p_grid, axis=1)

        s_rot = np.ascontiguousarray(s_rot)
        p_grid = np.ascontiguousarray(p_grid)

        return (
            torch.tensor(s_rot, dtype=torch.float32),
            torch.tensor(p_grid.flatten(), dtype=torch.float32),
            torch.tensor(v_vec, dtype=torch.float32)
        )

# ==========================================
# 4. MCTS 与 多进程 Pipe 评估逻辑
# ==========================================
class MCTSNode:
    def __init__(self, player_to_move, parent=None, prior=0.0):
        self.player_to_move = player_to_move  # 保存该节点轮到行动的绝对玩家 ID
        self.parent = parent
        self.children = {}
        self.visit_count = 0
        self.value_sum = np.zeros(NUM_PLAYERS, dtype=np.float32) # 存储 4 位玩家的绝对 Value 累加值
        self.prior = prior

    def value(self, player):
        return self.value_sum[player] / self.visit_count if self.visit_count > 0 else 0.0

class ProcessActorMCTS:
    def __init__(self, game, req_queue, pipe_conn, actor_id, c_puct=1.414):
        self.game = game
        self.req_queue = req_queue
        self.pipe_conn = pipe_conn
        self.actor_id = actor_id
        self.c_puct = c_puct

    def _eval_remote(self, tensor_state):
        self.req_queue.put((self.actor_id, tensor_state))
        return self.pipe_conn.recv()

    def search(self, board, p_curr, total_moves, num_simulations=40):
        valid_moves = self.game.get_valid_moves(board, p_curr, total_moves)
        if not valid_moves:
            return np.zeros(144, dtype=np.float32)

        root = MCTSNode(player_to_move=p_curr)
        init_tensor = self.game.board_to_tensor(board, p_curr)
        logits, _ = self._eval_remote(init_tensor)

        valid_mask = np.zeros(144, dtype=bool)
        for r, c in valid_moves:
            valid_mask[r * 12 + c] = True

        policy = safe_normalize(logits, valid_mask)
        epsilon = max(0.02, 0.25 * (0.95 ** (total_moves // 4)))
        noise = np.random.dirichlet([0.15] * len(valid_moves)) if len(valid_moves) > 0 else []

        # 根节点展开：为每个合法动作创建子节点，设置其下一步决策玩家 next_p
        for idx, (r, c) in enumerate(valid_moves):
            a_idx = r * 12 + c
            p_val = (1 - epsilon) * policy[a_idx] + epsilon * noise[idx] if len(noise) > 0 else policy[a_idx]
            next_b = self.game.execute_move(board, p_curr, (r, c))
            next_p = self.game.get_next_player(next_b, p_curr, total_moves + 1)
            root.children[a_idx] = MCTSNode(player_to_move=next_p, parent=root, prior=p_val)

        for _ in range(num_simulations):
            node = root
            curr_board = board.copy()
            curr_p = p_curr
            moves_cnt = total_moves

            # Selection 阶段：使用当前节点的决策玩家视角 acting_p 选择最佳动作
            while node.children:
                best_score = -float('inf')
                best_action, best_child = -1, None
                acting_p = node.player_to_move

                for action, child in node.children.items():
                    q_val = child.value(acting_p)
                    u = self.c_puct * child.prior * math.sqrt(node.visit_count + 1) / (1 + child.visit_count)
                    score = q_val + u
                    if score > best_score:
                        best_score, best_action, best_child = score, action, child

                r, c = best_action // 12, best_action % 12
                curr_board = self.game.execute_move(curr_board, curr_p, (r, c))
                moves_cnt += 1
                curr_p = self.game.get_next_player(curr_board, curr_p, moves_cnt)
                node = best_child

            # 修复死循环：已被访问过的叶子节点且无子节点，无需重复 Remote Eval
            if node.visit_count > 0 and not node.children:
                v_abs = node.value_sum / max(1, node.visit_count)
                curr = node
                while curr is not None:
                    curr.visit_count += 1
                    curr.value_sum += v_abs
                    curr = curr.parent
                continue

            # Expansion 与 Evaluation 阶段
            is_terminal, winner = self.game.check_terminal(curr_board, moves_cnt)
            if is_terminal:
                v_abs = np.zeros(4, dtype=np.float32)
                if winner != -1:
                    v_abs.fill(-0.33)
                    v_abs[winner] = 1.0

                curr = node
                while curr is not None:
                    curr.visit_count += 1
                    curr.value_sum += v_abs
                    curr = curr.parent
            else:
                v_moves = self.game.get_valid_moves(curr_board, curr_p, moves_cnt)
                if not v_moves:
                    leaf_tensor = self.game.board_to_tensor(curr_board, curr_p)
                    _, v_rel = self._eval_remote(leaf_tensor)

                    # 修复视角对齐：神经网络输出的 v_rel (相对视角) 转换为 v_abs (绝对视角)
                    v_abs = np.zeros(4, dtype=np.float32)
                    for p in range(4):
                        v_abs[(curr_p + p) % 4] = v_rel[p]

                    curr = node
                    while curr is not None:
                        curr.visit_count += 1
                        curr.value_sum += v_abs
                        curr = curr.parent
                else:
                    leaf_tensor = self.game.board_to_tensor(curr_board, curr_p)
                    l_out, v_rel = self._eval_remote(leaf_tensor)

                    # 修复视角对齐：相对视角神经网络评估输出转绝对视角向量
                    v_abs = np.zeros(4, dtype=np.float32)
                    for p in range(4):
                        v_abs[(curr_p + p) % 4] = v_rel[p]

                    v_mask = np.zeros(144, dtype=bool)
                    for r, c in v_moves:
                        v_mask[r * 12 + c] = True

                    p_exp = safe_normalize(l_out, v_mask)

                    # 展开新叶子节点：显式指定每个子节点对应的下位绝对玩家 next_p
                    for r, c in v_moves:
                        a_i = r * 12 + c
                        next_b = self.game.execute_move(curr_board, curr_p, (r, c))
                        next_p = self.game.get_next_player(next_b, curr_p, moves_cnt + 1)
                        node.children[a_i] = MCTSNode(player_to_move=next_p, parent=node, prior=p_exp[a_i])

                    curr = node
                    while curr is not None:
                        curr.visit_count += 1
                        curr.value_sum += v_abs
                        curr = curr.parent

        counts = np.zeros(144, dtype=np.float32)
        for action, child in root.children.items():
            counts[action] = child.visit_count
        
        sum_c = np.sum(counts)
        if sum_c > 0:
            return counts / sum_c
        
        return valid_mask.astype(np.float32) / np.sum(valid_mask)

def compute_final_value(board, winner):
    final_v = np.zeros(NUM_PLAYERS, dtype=np.float32)
    if winner != -1:
        final_v.fill(-0.33)
        final_v[winner] = 1.0
    else:
        orb_counts = np.zeros(NUM_PLAYERS, dtype=np.float32)
        for r in range(BOARD_SIZE):
            for c in range(BOARD_SIZE):
                owner = board[r, c, 0]
                if owner != -1:
                    orb_counts[owner] += board[r, c, 1]
        total_orbs = np.sum(orb_counts) + 1e-5
        final_v = np.clip((orb_counts / total_orbs) * 2.0 - 0.5, -1.0, 1.0)
    return final_v

def actor_worker_process(actor_id, game, req_queue, pipe_conn, result_queue, games_per_iter, num_iterations):
    torch.set_num_threads(1)
    mcts = ProcessActorMCTS(game, req_queue, pipe_conn, actor_id)

    for _ in range(num_iterations):
        cmd = pipe_conn.recv()
        if cmd == "EXIT":
            break

        for _ in range(games_per_iter):
            board = game.get_initial_board()
            p_curr = 0
            total_moves = 0
            history = []

            while True:
                probs = mcts.search(board, p_curr, total_moves, num_simulations=40)
                
                if np.sum(probs) == 0:
                    total_moves += 1
                    p_curr = game.get_next_player(board, p_curr, total_moves)
                    is_terminal, winner = game.check_terminal(board, total_moves)
                    if is_terminal or total_moves >= 200:
                        final_v = compute_final_value(board, winner)
                        game_data = [(s, p, np.array([final_v[(step+i)%4] for i in range(4)])) for s, p, step in history]
                        result_queue.put(game_data)
                        break
                    continue

                s_tensor = game.board_to_tensor(board, p_curr)
                history.append((s_tensor, probs, p_curr))

                if total_moves < 35 or np.random.rand() < 0.05:
                    probs_64 = probs.astype(np.float64)
                    probs_64 /= np.sum(probs_64)
                    action_idx = np.random.choice(len(probs_64), p=probs_64)
                else:
                    action_idx = np.argmax(probs)

                r, c = action_idx // BOARD_SIZE, action_idx % BOARD_SIZE
                board = game.execute_move(board, p_curr, (r, c))
                total_moves += 1
                p_curr = game.get_next_player(board, p_curr, total_moves)

                is_terminal, winner = game.check_terminal(board, total_moves)

                if is_terminal or total_moves >= 200:
                    final_v = compute_final_value(board, winner)
                    game_data = [(s, p, np.array([final_v[(step+i)%4] for i in range(4)])) for s, p, step in history]
                    result_queue.put(game_data)
                    break

# ==========================================
# 5. CoreML FP16 导出函数
# ==========================================
def export_to_coreml_fp16(model, save_path="ColorWarNet_fp16.mlmodel"):
    if not HAS_COREML: return
    print("\n📱 正在执行 FP16 半精度 CoreML (.mlmodel) 打包导出...")
    try:
        model_cpu = ColorWarNet(board_size=BOARD_SIZE, num_players=NUM_PLAYERS).eval()
        model_cpu.load_state_dict(model.state_dict())
        dummy_input = torch.rand(1, 4, 12, 12, dtype=torch.float32)
        traced_model = torch.jit.trace(model_cpu, dummy_input)
        input_shape = ct.TensorType(name="board_state", shape=(1, 4, 12, 12))
        outputs = [ct.TensorType(name="policy_logits"), ct.TensorType(name="value_vec")]
        with silence_stderr():
            mlmodel = ct.convert(traced_model, inputs=[input_shape], outputs=outputs, compute_precision=ct.precision.FLOAT16)
        mlmodel.save(save_path)
        print(f"🎉 FP16 CoreML 模型已成功导出至: {os.path.abspath(save_path)}")
    except Exception as e:
        print(f"⚠️ CoreML 导出跳过: ({e})")

# ==========================================
# 6. 主流水线
# ==========================================
def run_pipeline():
    start_time = time.time()
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    use_cuda = (device.type == "cuda")
    print(f"🚀 当前运算设备: {torch.cuda.get_device_name(0) if use_cuda else 'CPU 模式'}")

    model = ColorWarNet(board_size=BOARD_SIZE, num_players=NUM_PLAYERS).to(device)
    optimizer = optim.Adam(model.parameters(), lr=1e-3, weight_decay=1e-4)
    scaler = torch.amp.GradScaler('cuda', enabled=use_cuda)

    # Phase 1: 预热数据蒸馏
    print("\n🔥 === [Phase 1] 200,000 条预热数据蒸馏 (FP16 AMP 加速) ===")
    inputs, p_targets, v_targets = generate_heuristic_data(num_samples=200000)
    dataset = torch.utils.data.TensorDataset(inputs, p_targets, v_targets)
    loader = DataLoader(dataset, batch_size=256, shuffle=True, pin_memory=use_cuda, num_workers=0)

    model.train()
    for epoch in range(1, 16):
        total_loss = 0.0
        for x, target_p, target_v in loader:
            x, target_p, target_v = x.to(device), target_p.to(device), target_v.to(device)
            optimizer.zero_grad()
            
            with torch.amp.autocast(device_type='cuda', dtype=torch.float16, enabled=use_cuda):
                pred_p, pred_v = model(x)
                p_loss = -torch.mean(torch.sum(target_p * torch.log_softmax(pred_p, dim=1), dim=1))
                v_loss = nn.MSELoss()(pred_v, target_v)
                loss = p_loss + 2.0 * v_loss

            scaler.scale(loss).backward()
            scaler.step(optimizer)
            scaler.update()
            total_loss += loss.item()
        print(f"Epoch [{epoch:02d}/15] - FP16 Loss: {total_loss / len(loader):.4f}")

    # Phase 2: AlphaZero 自对弈
    print("\n⚔️ === [Phase 2] AlphaZero 自对弈 ===")
    game = ChainReactionGame(BOARD_SIZE, NUM_PLAYERS)
    replay_buffer = deque(maxlen=300000)

    num_actors = 12
    total_games_per_iter = 36  # 修改：单轮总对局数设为 36
    games_per_actor = total_games_per_iter // num_actors  # 每个 Actor 进程负责 3 局
    num_iterations = 25  # 修改：训练总轮数设为 25

    req_queue = Queue()
    result_queue = Queue()
    pipes = [mp.Pipe() for _ in range(num_actors)]
    parent_conns = [p[0] for p in pipes]
    child_conns = [p[1] for p in pipes]

    actors = []
    for a_id in range(num_actors):
        p = Process(target=actor_worker_process, args=(a_id, game, req_queue, child_conns[a_id], result_queue, games_per_actor, num_iterations))
        p.start()
        actors.append(p)

    try:
        for iteration in range(1, num_iterations + 1):
            iter_start = time.time()
            print(f"\n--- 迭代 [{iteration}/{num_iterations}] ---")

            for p_conn in parent_conns:
                p_conn.send("START")

            model.eval()
            finished_games = 0
            last_print_games = 0

            # 倾倒 result_queue 的辅助函数
            def drain_results():
                nonlocal finished_games, last_print_games
                while not result_queue.empty() and finished_games < total_games_per_iter:
                    try:
                        game_data = result_queue.get_nowait()
                        replay_buffer.extend(game_data)
                        finished_games += 1
                        if finished_games - last_print_games >= 6 or finished_games == total_games_per_iter:
                            print(f"  └─ ⚔️ 自对弈进度: {finished_games}/{total_games_per_iter} 局 ({(finished_games/total_games_per_iter)*100:.0f}%)", end='\r')
                            last_print_games = finished_games
                    except queue.Empty:
                        break

            with torch.inference_mode():
                while finished_games < total_games_per_iter:
                    drain_results()  # 1. 在收集 Batch 请求前实时倾倒对局数据

                    batch_requests = []
                    target_batch_size = 12
                    max_batch_size = 64
                    max_wait_time = 0.002
                    gather_start = time.perf_counter()

                    # 2. 收集来自 Actor 的 MCTS 推理请求
                    while len(batch_requests) < max_batch_size:
                        try:
                            batch_requests.append(req_queue.get_nowait())
                        except queue.Empty:
                            drain_results()  # 轮询间隙倾倒队列，防止 Actor 卡死
                            if len(batch_requests) >= target_batch_size or (time.perf_counter() - gather_start) >= max_wait_time:
                                break
                            time.sleep(0.0001)

                    if batch_requests:
                        tensors = np.array([r[1] for r in batch_requests], dtype=np.float32)
                        t_gpu = torch.from_numpy(tensors).to(device, non_blocking=True)
                        
                        with torch.amp.autocast(device_type='cuda', dtype=torch.float16, enabled=use_cuda):
                            logits, v_out = model(t_gpu)

                        logits_np = logits.float().cpu().numpy()
                        v_out_np = v_out.float().cpu().numpy()

                        for idx, a_id in enumerate([r[0] for r in batch_requests]):
                            parent_conns[a_id].send((logits_np[idx], v_out_np[idx]))

                    drain_results()  # 3. 推理发送完成后再次倾倒对局队列
            print()

            model.train()
            sample_size = min(len(replay_buffer), 200 * 256)
            sampled_data = random.sample(replay_buffer, sample_size)
            train_dataset = ReplayBufferDataset(sampled_data)
            train_loader = DataLoader(train_dataset, batch_size=256, shuffle=True, num_workers=0, pin_memory=use_cuda, drop_last=True)
            train_steps, total_train_loss = 0, 0.0

            for states, target_ps, target_vs in train_loader:
                if train_steps >= 200: break
                states, target_ps, target_vs = states.to(device), target_ps.to(device), target_vs.to(device)
                optimizer.zero_grad()
                
                with torch.amp.autocast(device_type='cuda', dtype=torch.float16, enabled=use_cuda):
                    pred_ps, pred_vs = model(states)
                    p_loss = -torch.mean(torch.sum(target_ps * torch.log_softmax(pred_ps, dim=1), dim=1))
                    v_loss = nn.MSELoss()(pred_vs, target_vs)
                    loss = p_loss + 2.0 * v_loss

                scaler.scale(loss).backward()
                scaler.step(optimizer)
                scaler.update()
                total_train_loss += loss.item()
                train_steps += 1

            print(f"⏱️ 迭代 [{iteration}/{num_iterations}] 耗时: {time.time() - iter_start:.2f}s | FP16 Loss: {total_train_loss/max(1, train_steps):.4f}")

    finally:
        for p_conn in parent_conns:
            try:
                p_conn.send("EXIT")
            except Exception:
                pass

        req_queue.close()
        result_queue.close()
        req_queue.cancel_join_thread()
        result_queue.cancel_join_thread()

        for p in actors: 
            p.join(timeout=1)
            if p.is_alive():
                p.terminate()
            
        for p_conn in parent_conns: p_conn.close()
        for c_conn in child_conns: c_conn.close()

    print("\n💾 保存 PyTorch 模型权重...")
    torch.save(model.state_dict(), "colorwar_12x12_model.pt")
    export_to_coreml_fp16(model, save_path="ColorWarNet_fp16.mlmodel")
    print(f"\n🎉 训练全流程顺利结束！总耗时: {(time.time() - start_time) / 3600:.2f} 小时")

if __name__ == '__main__':
    mp.set_start_method('spawn', force=True)
    run_pipeline()