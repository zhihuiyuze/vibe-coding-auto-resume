# vibe-coding-auto-resume

Enveloppez le CLI Claude Code dans tmux pour que vos longues tâches agentiques survivent aux rate limits, aux coupures SSH et aux runs nocturnes — sans surveiller l'horloge de reset.

[English](README.md) | [中文](README.zh.md) | [***Français***](README.fr.md) | [Русский](README.ru.md)

## Installation (une fois)

```bash
git clone https://github.com/zhihuiyuze/vibe-coding-auto-resume.git ~/dev/claude-auto-continue
cd ~/dev/claude-auto-continue
./install.sh
sudo apt install tmux  # seulement si absent — l'installeur vous le dit
source ~/.bashrc
```

L'installeur est idempotent. Il symlink `vibe-run`, `vibe-status`, `vibe-session-capture` dans `~/.local/bin/`, ajoute une fonction shell `vibe` à `~/.bashrc`, et ajoute un snippet tmux. Il ne touche jamais à `~/.claude/` et ne lance jamais `sudo` à votre place.

---

## Trois scénarios — choisissez le vôtre

### 1. Je démarre une nouvelle tâche Claude

```bash
cd ~/dev/<votre-projet>
vibe work                  # cd ici + ouvre une session tmux nommée
vibe run                   # remplace `claude` — mêmes flags, même UI
```

Utilisez Claude normalement. Quand le bloc 5 h est épuisé, `vibe run` le détecte, dort jusqu'au reset, et relance **le même UUID de session** automatiquement. Si la nouvelle modale interactive d'Anthropic apparaît (`What do you want to do? 1. Stop and wait …`), le wrapper sélectionne l'option sûre « Stop and wait » à votre place.

Pour laisser la session tourner et revenir plus tard : `Ctrl+b d`. Pour revenir : `vibe work`.

### 2. Je veux reprendre une session démarrée plus tôt

Si vous vous souvenez du UUID de session (depuis `~/.claude/projects/`, ou copié d'un log précédent) :

```bash
cd ~/dev/<votre-projet>
vibe work
vibe run --resume <session-uuid>
```

Si vous ne vous souvenez pas mais que c'est la session la plus récente sur ce projet :

```bash
vibe work
vibe run --mode continue                    # équivalent à `claude --continue` + reprise auto sur rate limit
```

Pour lister les candidats, regardez les noms de fichier JSONL :

```bash
ls -t ~/.claude/projects/$(pwd | sed 's|/|-|g')/*.jsonl | head -5
# le nom de fichier moins `.jsonl` est le UUID de session
```

### 3. SSH a sauté — comment vérifier que ça tourne encore et y revenir

La session tmux est le vrai propriétaire du process — `claude` est tenu par tmux, pas par votre shell. SSH meurt, la session vit. Étape par étape :

```bash
ssh vous@server                             # 1. reconnexion
tmux ls                                     # 2. votre session vibe-* est-elle toujours là ?
                                            #    attendu : ex. "vibe-default: 1 windows (...)"
vibe work                                   # 3. rattacher (ou `vibe work <name>` si nommée)
                                            #    vous atterrissez exactement où vous étiez
```

Une fois rattaché, scrollback pour voir ce qui s'est passé pendant votre absence : `Ctrl+b [`, puis PageUp / flèches, `q` pour sortir. Si un rate limit est tombé entre-temps, le wrapper l'a géré — vous verrez les entrées `[vibe-run] Sleeping … until …` et la reprise.

**Jeter un œil sans rattacher** (depuis une autre machine, juste un check) :

```bash
ssh vous@server "tmux ls"                                              # ce qui est vivant
ssh vous@server "tmux capture-pane -t vibe-default -p | tail -50"      # 50 dernières lignes du pane
ssh vous@server "vibe status"                                          # usage du bloc courant
```

**Si `tmux ls` répond `no server running`** — la machine a redémarré, ou tmux s'est fait OOM-killer. La session tmux est perdue, mais l'historique JSONL de Claude non. Reprenez via le scénario 2 ci-dessus (`vibe run --resume <uuid>` ou `vibe run --mode continue`).

---

## Optionnel : détection LLM plus intelligente

L1 (parsing JSONL) et L2 (regex sur le pane) couvrent les rate limits courants sans appel externe. Pour gérer les changements de wording du TUI et extraire les heures de reset que la regex manque, activez L3 :

```bash
echo 'DEEPSEEK_API_KEY=sk-...' >> ~/.config/vibe/env   # chmod 600, créé par l'installeur
chmod 600 ~/.config/vibe/env
source ~/.bashrc
```

Providers supportés : **DeepSeek** (le moins cher, ~0,05 $/bloc), **Anthropic Claude Haiku**, **OpenAI gpt-4o-mini**, **Ollama** (local, `[untested]` — en attente de validation GPU).

**Confidentialité** : avec L3 activé, les ~30 dernières lignes du pane (queue de conversation + previews de fichiers visibles) sont envoyées au provider choisi pour un seul appel de classification par event de limite. La redaction basique des secrets (`sk-*`, `Bearer *`, `*_SECRET=*`, base64 long) est activée par défaut mais n'est pas une garantie. Refusez l'opt-in (ou `vibe run --no-l3`) pour rester 100 % local.

---

## Ce qui se passe sous le capot

Quand `claude` sort, `vibe run` lance trois checks dans l'ordre :

- **L1** somme `message.usage.{input,output,cache_read}_tokens` sur les fichiers JSONL du projet courant pour savoir combien du bloc 5 h est consommé et quand il se reset.
- **L2** lance `tmux capture-pane` et grep la queue contre les chaînes verbatim du TUI (`5-hour limit reached ∙ resets …`, `weekly limit reached`, `Approaching 5-hour limit`, plus la nouvelle modale « Stop and wait for limit to reset »). Il extrait l'heure de reset.
- **L3** (opt-in) envoie la même queue à un LLM et reçoit `{status, reset_time, idle, modal_open}` pour les cas que L2 ne sait pas parser.

Quand `claude` sort proprement ou sur une vraie erreur (crash, MCP failure, /exit), le wrapper sort avec le même code — il ne retente **pas** aveuglément. La reprise auto ne démarre que sur un signal de rate limit positivement détecté. Voir [`docs/architecture.md`](docs/architecture.md) et [`docs/design/001-three-layer-detection.md`](docs/design/001-three-layer-detection.md).

## Flags CLI

```
vibe run [...args]
  --resume <uuid>          reprendre une session spécifique (utilisé pour tous les cycles)
  --threshold <0..1>       plafond souple opt-in (off par défaut — brûle le bloc)
  --max-cycles <n>         cycles de reprise par invocation (0 = illimité, défaut 1)
  --mode auto|session-id|continue
  --provider deepseek|claude|openai|ollama
  --no-l3                  force L1+L2 seulement
  --dangerously-skip-permissions
  -p "prompt"
  ... tous les autres flags passent à claude tels quels
```

## Variables d'environnement (principales)

| Variable | Défaut | Rôle |
|---|---|---|
| `CC_LLM_PROVIDER` | auto-détection | `deepseek` / `claude` / `openai` / `ollama` / `none` |
| `CC_USAGE_THRESHOLD` | _absent_ (off) | Plafond souple opt-in (ex. `0.80`) pour réserver du budget |
| `CC_RESUME_MODE` | `auto` | `auto` / `session-id` (UUID strict) / `continue` |
| `CC_RESUME_MAX_CYCLES` | `1` | `0` = cycles de reprise illimités par invocation |
| `CC_SLEEP_PAD` | `60` | Secondes ajoutées à l'heure de reset avant relance |

Les autres réglages (`CC_LLM_REDACT`, `CC_PANE_TAIL_LINES`, `CC_MODAL_POLL_INTERVAL`, …) sont documentés en tête de `bin/vibe-run`.

## Multi-session

`vibe work <name>` crée une session tmux + un répertoire d'état isolés. Utile pour faire tourner plusieurs tâches Claude en parallèle :

```bash
vibe work feature-a    # session tmux "vibe-feature-a"
# Ctrl+b d, puis dans un autre shell :
vibe work bugfix       # session tmux "vibe-bugfix", cache UUID séparé
```

`vibe work` sans nom utilise un nom déterministe-aléatoire dérivé du hash du cwd — revenir au même projet retombe toujours sur la même session.

## Contribuer

Lisez [`AGENTS.md`](AGENTS.md) d'abord — le point d'entrée unique. Le projet suit un **workflow spec-first** : chaque feature commence par un design doc `docs/design/00X-<name>.md` ([template](docs/design/README.md)) revu avant code.

Si Claude Code montre un jour un message de rate limit ou de modal qu'on ne matche pas, collez-le verbatim dans `tests/fixtures/<name>.txt` et ouvrez une PR.

## Licence

MIT.
