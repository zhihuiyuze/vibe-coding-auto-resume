# vibe-coding-auto-resume

在 tmux 里包一层 Claude Code CLI，长 agentic 任务能跨过 rate limit、SSH 断线、整夜跑——不用你盯着 reset 时间。

[English](README.md) | [***中文***](README.zh.md) | [Français](README.fr.md) | [Русский](README.ru.md)

## 安装（一次性）

```bash
git clone https://github.com/zhihuiyuze/vibe-coding-auto-resume.git ~/dev/claude-auto-continue
cd ~/dev/claude-auto-continue
./install.sh
sudo apt install tmux  # 没装时安装器会提示
source ~/.bashrc
```

安装脚本幂等。把 `vibe-run`、`vibe-status`、`vibe-session-capture` 软链到 `~/.local/bin/`，往 `~/.bashrc` 写一个 `vibe` shell 函数，往 `~/.tmux.conf` 追加一小段配置。不动 `~/.claude/` 下任何文件，也不会替你 sudo。

---

## 三个场景，对号入座

### 1. 我要起一个新的 Claude 任务

```bash
cd ~/dev/<your-project>
vibe work                  # cd 到这里 + 开一个命名 tmux session
vibe run                   # 用它替代 `claude`，参数一致 UI 一致
```

之后正常用 Claude 即可。当 5 小时 block 烧光时，`vibe run` 自动察觉，sleep 到 reset，然后用**同一个 session UUID** 重新启动。如果 Anthropic 弹出新的交互式 modal（`What do you want to do? 1. Stop and wait …`），wrapper 会替你选安全选项 "Stop and wait"。

想暂时离开 session 留它继续跑：`Ctrl+b d`。回来：`vibe work`。

### 2. 我想接着之前开过的某个会话继续

如果你记得 session UUID（从 `~/.claude/projects/` 翻出来，或之前的日志里抄的）：

```bash
cd ~/dev/<your-project>
vibe work
vibe run --resume <session-uuid>
```

如果不记得 UUID 但确定是这个项目最近一个 session：

```bash
vibe work
vibe run --mode continue                    # 等价于 claude --continue，外加 hit limit 自动续接
```

列出可选 UUID：

```bash
ls -t ~/.claude/projects/$(pwd | sed 's|/|-|g')/*.jsonl | head -5
# 文件名去掉 .jsonl 就是 session UUID
```

### 3. SSH 断了之后怎么确认还在跑、怎么重连恢复

tmux session 才是进程的真正归属——`claude` 是被 tmux 拽着的，跟你的 shell 无关。SSH 死了 session 不会死。逐步操作：

```bash
ssh you@server                              # 1. 重新连上
tmux ls                                     # 2. 看 vibe-* session 还在不在
                                            #    正常应输出类似 "vibe-default: 1 windows (...)"
vibe work                                   # 3. 重新 attach（用了自定义名字就 `vibe work <name>`）
                                            #    一进去就是离开时的现场
```

attach 后想看你走开这段时间发生了什么：`Ctrl+b [` 进入翻页模式，PageUp / 方向键往上翻，`q` 退出。如果中间真 hit 了 limit，wrapper 已经替你处理过了——会看到 `[vibe-run] Sleeping … until …` 和恢复运行的日志。

**不 attach 只想偷瞄一眼**（比如换台机器看看状态）：

```bash
ssh you@server "tmux ls"                                              # 看什么 session 还活着
ssh you@server "tmux capture-pane -t vibe-default -p | tail -50"      # 抓 pane 末尾 50 行
ssh you@server "vibe status"                                          # 当前 block 用量
```

**如果 `tmux ls` 输出 `no server running`** —— 通常是机器重启了，或 tmux 被 OOM kill 了。tmux session 没了，但 Claude 的 JSONL 历史还在。走上面场景 2（`vibe run --resume <uuid>` 或 `vibe run --mode continue`）从原 session 续接即可。

---

## 可选：开 LLM 增强检测

L1（JSONL 解析）和 L2（tmux pane regex）在常见 rate limit 场景下零外发就够用。想更稳地应对 TUI 文案变化、抽 L2 regex 抓不到的 reset 时间，可以 opt-in L3：

```bash
echo 'DEEPSEEK_API_KEY=sk-...' >> ~/.config/vibe/env   # 安装器已建（chmod 600）
chmod 600 ~/.config/vibe/env
source ~/.bashrc
```

支持的 provider：**DeepSeek**（最便宜，约 $0.05/block）、**Anthropic Claude Haiku**、**OpenAI gpt-4o-mini**、**Ollama**（本地，`[untested]`，等 GPU 验证）。

**隐私说明**：L3 启用后，tmux pane 末尾约 30 行（对话尾、可见文件预览）会在每次限额事件时被发给所选 provider 做一次分类调用。默认开启基础脱敏（`sk-*`、`Bearer *`、`*_SECRET=*`、长 base64）但**不保证**全覆盖。Opt-in 时选 no（或运行时 `vibe run --no-l3`）继续走完全本地的 L1+L2。

---

## 工作原理

当 `claude` 退出时，`vibe run` 按顺序跑三个判断：

- **L1** sum 当前项目 JSONL 里的 `message.usage.{input,output,cache_read}_tokens`，知道 5 小时 block 烧了多少、什么时候 reset。
- **L2** 跑 `tmux capture-pane` 抓 pane 尾部，grep 已知的 TUI 文案（`5-hour limit reached ∙ resets ...`、`weekly limit reached`、`Approaching 5-hour limit`，加上新的交互式 modal "Stop and wait for limit to reset"），抽出 reset 时间。
- **L3**（可选）把同一份 pane 尾部发给 LLM，拿到 `{status, reset_time, idle, modal_open}` 结构化 JSON，处理 L2 解析不了的情况。

当 `claude` 正常退出或遇到真错误（崩溃、MCP 失败、/exit）时，wrapper 用同样的 exit code 退出——**不**会瞎重试。自动续接只在确认检测到 rate-limit 信号时触发。完整原理见 [`docs/architecture.md`](docs/architecture.md) 和 [`docs/design/001-three-layer-detection.md`](docs/design/001-three-layer-detection.md)。

## CLI 参数

```
vibe run [...args]
  --resume <uuid>          恢复指定 session（所有续接 cycle 都用它）
  --threshold <0..1>       opt-in 软上限（默认关——榨干当前 block）
  --max-cycles <n>         本次调用允许多少次续接（0 = 无限，默认 1）
  --mode auto|session-id|continue
  --provider deepseek|claude|openai|ollama
  --no-l3                  强制只走 L1+L2
  --dangerously-skip-permissions
  -p "prompt"
  ... 其他参数原样透传给 claude
```

## 环境变量（常用）

| 变量 | 默认 | 用途 |
|---|---|---|
| `CC_LLM_PROVIDER` | 自动探测 | `deepseek` / `claude` / `openai` / `ollama` / `none` |
| `CC_USAGE_THRESHOLD` | _未设_（关） | opt-in 软上限（例如 `0.80`）留交互预算 |
| `CC_RESUME_MODE` | `auto` | `auto` / `session-id`（严格 UUID） / `continue` |
| `CC_RESUME_MAX_CYCLES` | `1` | `0` = 每次调用无限续接 |
| `CC_SLEEP_PAD` | `60` | reset 时间后再加几秒才 relaunch |

其他不常用的开关（`CC_LLM_REDACT`、`CC_PANE_TAIL_LINES`、`CC_MODAL_POLL_INTERVAL` 等）在 `bin/vibe-run` 文件头部有注释。

## 多会话

`vibe work <name>` 起一个隔离的 tmux session + 状态目录。并行跑多个 Claude 任务时用：

```bash
vibe work feature-a    # tmux session "vibe-feature-a"
# Ctrl+b d，到另一个 shell：
vibe work bugfix       # tmux session "vibe-bugfix"，独立 session UUID 缓存
```

`vibe work` 不带名字时，用 cwd 哈希算一个确定性随机名——同一个项目永远 land 在同一个 session 上。

## 参与贡献

先读 [`AGENTS.md`](AGENTS.md)——贡献者的唯一入口。本项目用 **spec-first 工作流**：每个 feature 先写设计文档 `docs/design/00X-<name>.md`（[模板](docs/design/README.md)），评审通过再写代码。

特别欢迎补 TUI 样本：Claude Code 哪天吐出我们还没匹配到的限额/modal 文案，verbatim 贴到 `tests/fixtures/<name>.txt` 然后开 PR。

## License

MIT。
