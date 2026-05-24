# vibe-coding-auto-resume

Reprise automatique des sessions Claude Code CLI après les rate limits : les tâches agentiques longues, le vibe coding et les jobs nocturnes survivent aux limites de 5 heures et hebdomadaires sans redémarrage manuel.

[English](README.md) | [中文](README.zh.md) | [***Français***](README.fr.md) | [Русский](README.ru.md)

## Le problème

Si vous utilisez Claude Code (`claude`) pour du vrai travail — tâches agentiques longues, refactors de plusieurs heures, sessions de vibe coding via SSH — vous finissez par taper le mur :

- La fenêtre de rate limit de 5 heures coupe en plein milieu d'une tâche. Il faut retenir l'heure de reset et relancer `claude --continue` à la main.
- Les limites hebdomadaires font pareil, sur une horloge plus longue.
- Une coupure SSH tue le process. Vous revenez du déjeuner, la session a disparu.
- Aucun moyen intégré de voir combien du block courant a été consommé.
- Les wrappers existants basés sur le texte du TUI cassent dès que Claude reformule un message.

`vibe-coding-auto-resume` est un petit ensemble de scripts bash qui règle tout cela sans dépendances lourdes.

## Ce que ça fait

- **Lance `claude` dans tmux** pour que les coupures SSH, la fermeture du terminal ou la mise en veille du laptop ne tuent pas la session.
- **Détection des rate limits en trois couches** : parsing JSONL de `~/.claude/projects/*.jsonl` (L1), regex sur le pane tmux contre le texte verbatim du TUI (L2), classification LLM optionnelle (L3) pour les changements de wording et les edge cases.
- **Reprise auto après reset** : dort jusqu'à l'heure de reset extraite + un petit pad, puis relance via `claude --resume <session-uuid>` (préféré, préserve le cache) ou `claude --continue` (fallback).
- **Capture automatique du session UUID** en surveillant le répertoire JSONL, pour que la reprise vise la session exacte et évite le bug d'invalidation de cache de `--continue`.
- **Fichier de continuité `HANDOFF.md`** pour le contexte qui doit survivre même à un redémarrage complet.
- **L1+L2 sans dépendances externes** (juste `bash`, `jq`, `tmux`, `curl`). L3 est opt-in et désactivé par défaut.

Un daemon de monitoring du soft cap en arrière-plan (v2) qui prévient Claude à l'approche de la limite pour qu'il sauvegarde l'avancement est **planifié, pas encore implémenté**.

## Installation

```bash
git clone https://github.com/<user>/vibe-coding-auto-resume.git ~/dev/claude-auto-continue
cd ~/dev/claude-auto-continue
./install.sh
sudo apt install tmux  # si absent
source ~/.bashrc
```

L'installateur est idempotent : il crée des symlinks `vibe-run` et `vibe-session-capture` dans `~/.local/bin/`, ajoute un petit snippet à `~/.tmux.conf` et une fonction `vibe work` dans `~/.bashrc`. Il ne touche à rien sous `~/.claude/`.

## Utilisation

Workflow typique :

```bash
vibe work            # entre dans la session tmux "claude" au cwd de votre projet
vibe-run      # à utiliser à la place de `claude` — mêmes flags, même comportement
# Ctrl+b d pour détacher. SSH peut tomber ; la session continue.
# Plus tard : vibe work à nouveau pour réattacher.
```

Quand `claude` sort à cause d'un rate limit, `vibe-run` parse l'heure de reset, dort jusque-là (+60s de pad), puis reprend la même session UUID. Quand `claude` sort proprement ou sur une vraie erreur, le wrapper sort avec le même code — il ne retente **pas** aveuglément.

## Activation optionnelle du LLM L3

L1 (parsing JSONL) et L2 (regex sur le pane) couvrent les cas courants sans appel externe. Pour mieux gérer les changements de wording du TUI et les edge cases — et pour extraire les heures de reset que la regex L2 manque — on peut activer la classification LLM L3.

Providers supportés :

- **DeepSeek** (`DEEPSEEK_API_KEY`, modèle `deepseek-chat`) — le moins cher
- **Anthropic Claude** (`ANTHROPIC_API_KEY`, modèle `claude-haiku-4-5`)
- **OpenAI** (`OPENAI_API_KEY`, modèle `gpt-4o-mini`)
- **Ollama** (local, `OLLAMA_HOST`) — interface implémentée, actuellement `[untested]`, en attente de validation sur GPU

Pour activer :

```bash
export DEEPSEEK_API_KEY=sk-...   # à ajouter dans ~/.bashrc pour la persistance
./install.sh                     # relancer ; il détecte la clé et propose l'opt-in
source ~/.bashrc
```

**Note de confidentialité** : quand L3 est activé, les ~30 dernières lignes de votre pane tmux (queue de conversation, previews de fichiers) sont envoyées au provider choisi pour classification. Une redaction basique des secrets (`sk-*`, `Bearer *`, `*_SECRET=*`, base64 long) est activée par défaut, mais **pas** une garantie. N'activez pas L3 sur un pane qui contient des données que vous ne colleriez pas dans l'UI de chat du provider. Refuser l'opt-in maintient le mode L1+L2 même si une clé est présente.

## Comment fonctionne la détection (TL;DR)

Les trois couches tournent dans l'ordre. **L1** sait en continu combien du block de 5 heures a été consommé en sommant `message.usage.{input,output,cache_read}_tokens` sur les fichiers JSONL du projet courant ; c'est ce qui pilote le refus pre-flight au soft cap. **L2** lance `tmux capture-pane` à la sortie et grep la queue contre les chaînes verbatim de rate limit (`5-hour limit reached ∙ resets ...`, `weekly limit reached`, `Approaching 5-hour limit`) et extrait l'heure de reset. **L3** (si opt-in) envoie cette même queue à un LLM et reçoit en retour un JSON structuré `{status, reset_time, idle, modal_open}` pour les cas que L2 ne sait pas parser.

Voir [`docs/architecture.md`](docs/architecture.md) et [`docs/design/001-three-layer-detection.md`](docs/design/001-three-layer-detection.md) pour la justification complète.

## Variables d'environnement

| Variable | Défaut | Rôle |
|---|---|---|
| `CC_LLM_PROVIDER` | auto-détection, ou `none` | Choisit le provider L3 (`deepseek` / `claude` / `openai` / `ollama` / `none`). `none` force L1+L2 même si des clés sont présentes. |
| `CC_USAGE_THRESHOLD` | `0.75` | Fraction du soft cap. Pre-flight refuse de lancer une nouvelle query au-dessus. |
| `CC_RESUME_MODE` | `auto` | `auto` = `--resume <sid>` puis fallback `--continue`. `session-id` = UUID strict. `continue` = toujours `--continue`. |
| `CC_RESUME_MAX_CYCLES` | `1` | Nombre de cycles de reprise auto par invocation du wrapper (`0` = illimité). |
| `CC_COMPACTION_CHOICE` | `keep` | Sur le rare prompt de compaction (contexte trop large) après reprise : `keep` (contexte complet) ou `compact` (laisse Claude résumer). |

Les autres réglages moins courants (`CC_SLEEP_PAD`, `CC_LLM_REDACT`, `CC_PANE_TAIL_LINES`, `CC_PEAK_FALLBACK`, `CC_SESSION_FILE`, `CC_LLM_MODEL`) sont documentés en tête de `bin/vibe-run`.

## Contribuer

Lisez [`AGENTS.md`](AGENTS.md) d'abord — c'est le point d'entrée unique pour les contributeurs. Ce projet suit un **workflow spec-first** : chaque feature commence par un design doc `docs/design/00X-<name>.md` (template dans [`docs/design/README.md`](docs/design/README.md)) revu avant qu'une ligne de code soit écrite. Les bug fixes et petits tweaks peuvent partir directement en PR.

Les nouveaux patterns TUI sont particulièrement bienvenus : si Claude Code émet un jour un message de rate limit ou de modal qu'on ne matche pas encore, collez-le verbatim dans `tests/fixtures/<name>.txt` et ouvrez une PR.

## Licence

MIT.
