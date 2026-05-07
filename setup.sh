#!/usr/bin/env bash
#
# WSL setup script.
# Runs inside a fresh Ubuntu WSL shell. Idempotent — safe to re-run on failure.
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/emilhasseltoft/wsl-setup/main/setup.sh -o /tmp/setup.sh && bash /tmp/setup.sh
#
set -euo pipefail

# ---------- logging ----------
LOG_FILE="/tmp/wsl-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[1;31m'
NC=$'\033[0m'

msg()  { echo -e "${GREEN}>>${NC} $1"; }
warn() { echo -e "${YELLOW}!!${NC} $1"; }
err()  { echo -e "${RED}xx${NC} $1" >&2; }

TOTAL_STEPS=11
CURRENT_STEP=0
step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  echo
  echo -e "${GREEN}━━━ Step ${CURRENT_STEP}/${TOTAL_STEPS}: $1 ━━━${NC}"
}

# Run a command up to 3 times with a 5s delay. For network ops that may hit
# transient DNS/connectivity failures.
retry() {
  local n=1 max=3 delay=5
  while true; do
    if "$@"; then
      return 0
    fi
    if (( n >= max )); then
      err "Command failed after ${max} attempts: $*"
      return 1
    fi
    warn "Attempt ${n}/${max} failed, retrying in ${delay}s..."
    sleep "$delay"
    n=$((n + 1))
  done
}

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
on_error() {
  local exit_code=$?
  err ""
  err "Setup failed during step ${CURRENT_STEP}/${TOTAL_STEPS}."
  err "Look above for the error, fix it, then re-run:"
  err "  bash ${SCRIPT_PATH}"
  err ""
  err "Full log: ${LOG_FILE}"
  exit "$exit_code"
}
trap on_error ERR

# ---------- step 1: preflight ----------
step "Checking environment"

if ! grep -qi microsoft /proc/version 2>/dev/null; then
  err "This script must run inside WSL."
  err "Detected: $(uname -a)"
  exit 1
fi

if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
  err "This script requires Ubuntu."
  err "Detected: $(grep PRETTY_NAME /etc/os-release 2>/dev/null || echo unknown)"
  exit 1
fi

if ! curl -sf --max-time 10 https://github.com -o /dev/null; then
  err "Cannot reach github.com. Check your internet connection or VPN, then re-run."
  exit 1
fi

msg "WSL Ubuntu detected, internet works. Good."

# ---------- step 2: sudo keep-alive ----------
step "Getting admin access"
echo "This script needs admin access to install software."
echo "You'll be asked for your password once — after that, it stays unlocked until the script finishes."
echo
sudo -v

# Background loop refreshes sudo every 60s so long apt commands don't trigger another prompt.
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null || true' EXIT

# ---------- step 3: identity ----------
step "Configuring your identity"

read -r -p "Your full name (e.g. Jane Doe): " GIT_USER_NAME </dev/tty
read -r -p "Your GitHub email (work or personal): " GIT_USER_EMAIL </dev/tty

git config --global user.name  "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"
git config --global init.defaultBranch main
git config --global core.editor "nano"
git config --global pull.rebase false

msg "Git configured for ${GIT_USER_NAME} <${GIT_USER_EMAIL}>"

# ---------- step 4: system update ----------
step "Updating system packages"
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y curl git ca-certificates gnupg lsb-release locales nano

# locale fix — silences "cannot change locale" warnings on fresh Ubuntu
if ! locale -a 2>/dev/null | grep -qi "en_US.utf8"; then
  sudo locale-gen en_US.UTF-8
  sudo update-locale LANG=en_US.UTF-8
fi

# ---------- step 5: zsh + oh-my-zsh + plugins ----------
step "Installing Zsh, Oh My Zsh, and plugins"
sudo apt-get install -y zsh

if [ ! -d "$HOME/.oh-my-zsh" ]; then
  # Download installer to a file first so a curl failure is loud (not swallowed
  # by command substitution into an empty sh -c).
  OMZ_INSTALLER="$(mktemp)"
  retry curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors \
    https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh \
    -o "$OMZ_INSTALLER"
  # Wrap the installer execution in retry too — its internal git clone of
  # ohmyzsh.git can hit the same transient DNS failures we see elsewhere.
  # rm -rf clears any partial state from a previous failed attempt so the
  # installer can run fresh on each retry.
  retry bash -c "rm -rf '$HOME/.oh-my-zsh'; RUNZSH=no CHSH=no sh '$OMZ_INSTALLER'"
  rm -f "$OMZ_INSTALLER"
  if [ ! -d "$HOME/.oh-my-zsh" ]; then
    err "Oh My Zsh installer ran but ~/.oh-my-zsh wasn't created. Re-run the script."
    exit 1
  fi
fi

ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

# fzf
if [ ! -d "$HOME/.fzf" ]; then
  retry git clone --depth 1 https://github.com/junegunn/fzf.git "$HOME/.fzf"
fi
"$HOME/.fzf/install" --key-bindings --completion --no-update-rc >/dev/null

clone_or_skip() {
  local url="$1" dir="$2"
  if [ ! -d "$dir" ]; then
    retry git clone --depth 1 "$url" "$dir"
  fi
}
clone_or_skip https://github.com/Aloxaf/fzf-tab.git                       "$ZSH_CUSTOM/plugins/fzf-tab"
clone_or_skip https://github.com/zsh-users/zsh-syntax-highlighting.git    "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
clone_or_skip https://github.com/zsh-users/zsh-history-substring-search.git "$ZSH_CUSTOM/plugins/zsh-history-substring-search"

# .zshrc managed block — idempotent regenerate
ZSHRC="$HOME/.zshrc"
[ -f "$ZSHRC" ] || touch "$ZSHRC"

# Update the plugins=(...) line that oh-my-zsh's template wrote
if grep -q '^plugins=(' "$ZSHRC"; then
  sed -i 's|^plugins=(.*)|plugins=(git fzf fzf-tab zsh-syntax-highlighting)|' "$ZSHRC"
else
  echo 'plugins=(git fzf fzf-tab zsh-syntax-highlighting)' >> "$ZSHRC"
fi

# Strip any previous managed block, then write a fresh one at the end
sed -i '/^# >>> wsl-setup managed/,/^# <<< wsl-setup managed/d' "$ZSHRC"

cat >> "$ZSHRC" <<'EOF'

# >>> wsl-setup managed (do not edit this block) >>>
# Workaround for an OMZ bug where the async git prompt errors on every
# command when these aren't pre-initialized. Safe: reassignments by themes
# or OMZ itself still work normally.
typeset -gA _OMZ_ASYNC_OUTPUT
: ${RPROMPT:=""}
: ${RPS1:=""}
: ${RPS2:=""}
: ${RPS3:=""}
: ${RPS4:=""}
: ${_omz_git_prompt_info:=""}
: ${_OMZ_ASYNC_OUTPUT[_omz_git_prompt_info]:=""}

# Sourced after oh-my-zsh.sh so order-sensitive plugins work correctly.
[ -f "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ] && \
  source "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
[ -f "$ZSH_CUSTOM/plugins/zsh-history-substring-search/zsh-history-substring-search.zsh" ] && \
  source "$ZSH_CUSTOM/plugins/zsh-history-substring-search/zsh-history-substring-search.zsh"

bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down

export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border'
[ -f "$HOME/.fzf.zsh" ] && source "$HOME/.fzf.zsh"

# ~/.local/bin contains user-installed binaries (mise, claude, etc.)
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# mise (per-project runtime versions)
[ -x "$HOME/.local/bin/mise" ] && eval "$($HOME/.local/bin/mise activate zsh)"

# wsl-setup first-run walkthrough (self-deletes after first run)
[ -f "$HOME/.config/wsl-setup-firstrun.zsh" ] && source "$HOME/.config/wsl-setup-firstrun.zsh"
# <<< wsl-setup managed <<<
EOF

# ---------- step 6: docker (official) ----------
step "Installing Docker (official repo)"

sudo install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.asc ]; then
  retry sudo curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
fi

if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -y
fi

sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

if ! id -nG "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER"
  msg "Added $USER to docker group (takes effect after WSL restart)."
fi

# ---------- step 7: gh CLI ----------
step "Installing GitHub CLI"

if ! command -v gh >/dev/null 2>&1; then
  retry bash -c 'curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/etc/apt/keyrings/githubcli-archive-keyring.gpg status=none'
  sudo chmod 644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
  ARCH="$(dpkg --print-architecture)"
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  sudo apt-get update -y
  sudo apt-get install -y gh
fi

# ---------- step 8: mise ----------
step "Installing mise"
if [ ! -x "$HOME/.local/bin/mise" ]; then
  retry bash -c 'curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors https://mise.run | sh'
fi
msg "Note: mise's installer suggests adding a line to ~/.bashrc — you can ignore that."
msg "      This script already activates mise in zsh (your default shell after restart)."

# ---------- step 9: Claude Code ----------
step "Installing Claude Code"
if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
  retry bash -c 'curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors https://claude.ai/install.sh | bash'
fi
msg "Note: Claude's installer warns about ~/.local/bin not being in PATH and"
msg "      suggests editing ~/.bashrc — you can ignore that."
msg "      This script adds ~/.local/bin to PATH in zsh (your shell after restart)."

# ---------- step 10: GitHub auth + SSH key ----------
step "Authenticating with GitHub"

if gh auth status >/dev/null 2>&1; then
  msg "Already authenticated with GitHub. Skipping login."
else
  echo "Next, you'll log in to GitHub via your browser."
  echo "Choose: GitHub.com → SSH → Login with a web browser."
  echo
  read -r -p "Press Enter to start..." _ </dev/tty
  gh auth login --hostname github.com --git-protocol ssh --web </dev/tty
fi

# gh's auth flow doesn't reliably create + upload an SSH key, so do it
# explicitly. Idempotent: skips generation if a key already exists, and
# skips upload if this exact public key is already on GitHub.

# 1. Generate an SSH key if none exists.
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
  msg "Generating SSH key (~/.ssh/id_ed25519)..."
  ssh-keygen -t ed25519 -C "$GIT_USER_EMAIL" -f "$HOME/.ssh/id_ed25519" -N ""
fi

# 2. Ensure the gh token has admin:public_key so we can upload the key.
if ! gh auth status 2>&1 | grep -q "admin:public_key"; then
  msg "Adding admin:public_key scope to gh auth (opens browser)..."
  gh auth refresh -h github.com -s admin:public_key </dev/tty
fi

# 3. Upload the public key if it's not already on the account.
PUBKEY_BODY="$(awk '{print $2}' "$HOME/.ssh/id_ed25519.pub")"
if ! gh api /user/keys --jq '.[].key' 2>/dev/null | grep -qF "$PUBKEY_BODY"; then
  msg "Uploading SSH public key to GitHub..."
  gh ssh-key add "$HOME/.ssh/id_ed25519.pub" --title "WSL $(hostname) $(date +%Y-%m-%d)"
else
  msg "SSH public key already registered on GitHub. Skipping upload."
fi

gh auth setup-git

# 4. Verify SSH to GitHub. ssh -T against GitHub always exits 1, so check
# stderr for the success message instead of the exit code.
SSH_OUTPUT="$(ssh -T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 git@github.com 2>&1 || true)"
if echo "$SSH_OUTPUT" | grep -q "successfully authenticated"; then
  msg "SSH to GitHub: working ✓"
else
  warn "SSH connectivity test didn't authenticate. Output:"
  warn "$SSH_OUTPUT"
  warn "You may need to debug manually after setup completes."
fi

# ---------- step 11: default shell + first-run hook ----------
step "Setting Zsh as the default shell and preparing the first-run guide"

CURRENT_SHELL="$(getent passwd "$USER" | cut -d: -f7)"
ZSH_PATH="$(which zsh)"
if [ "$CURRENT_SHELL" != "$ZSH_PATH" ]; then
  sudo chsh -s "$ZSH_PATH" "$USER"
  msg "Default shell changed to zsh."
fi

mkdir -p "$HOME/.config"
cat > "$HOME/.config/wsl-setup-firstrun.zsh" <<'FIRSTRUN_EOF'
# WSL setup — first-run walkthrough.
# This file is sourced from ~/.zshrc on the first zsh start after setup.
# It self-deletes when complete so it never runs twice.

emulate -L zsh
setopt local_options no_unset

GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

print
print "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
print "${GREEN}  Welcome! Let's finish your setup together.   ${NC}"
print "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
print

# --- Step 1: Claude Code sign-in ---
print "${GREEN}Step 1 of 3: Sign in to Claude Code${NC}"
print "Claude Code is the AI assistant you'll use to write code."
print "When you press Enter, Claude will open and ask you to sign in via your browser."
print "After signing in, type ${YELLOW}/exit${NC} (or press Ctrl+C) to come back here."
print
read -r "?Press Enter to launch Claude... "
claude || true
print

# --- Step 2: VS Code WSL extension ---
print "${GREEN}Step 2 of 3: VS Code with WSL${NC}"
print "On Windows:"
print "  1. Open ${YELLOW}VS Code${NC} (install from https://code.visualstudio.com if you don't have it)"
print "  2. Click the ${YELLOW}Extensions${NC} icon in the left sidebar (or press Ctrl+Shift+X)"
print "  3. Search for ${YELLOW}WSL${NC} (the one published by Microsoft)"
print "  4. Click ${YELLOW}Install${NC}"
print
read -r "?Press Enter once the WSL extension is installed... "
print

# --- Step 3: Clone first repo ---
print "${GREEN}Step 3 of 3: Clone your first repository${NC}"
print "Paste the URL of a GitHub repository you want to work on."
print "Examples:"
print "  ${YELLOW}git@github.com:bunker-holding/some-project.git${NC}"
print "  ${YELLOW}https://github.com/bunker-holding/some-project.git${NC}"
print "Or just press Enter to skip — you can clone later."
print
read -r "?Repo URL: " REPO_URL

if [[ -n "$REPO_URL" ]]; then
  mkdir -p "$HOME/code"
  cd "$HOME/code"
  if git clone "$REPO_URL"; then
    REPO_NAME="${${REPO_URL##*/}%.git}"
    cd "$REPO_NAME"
    print
    print "${GREEN}✓ Cloned to ~/code/${REPO_NAME}${NC}"
    print
    print "To open it in VS Code on Windows, run this from here:"
    print "  ${YELLOW}code .${NC}"
    print
    print "VS Code will open and connect back into WSL automatically."
  else
    print
    print "${YELLOW}Couldn't clone that URL. You can try again later:${NC}"
    print "  ${YELLOW}cd ~/code && git clone <url>${NC}"
  fi
else
  print "Skipped. To clone later:"
  print "  ${YELLOW}cd ~/code && git clone <url>${NC}"
fi

print
print "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
print "${GREEN}  All set! You're ready to start working.      ${NC}"
print "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
print

# Self-delete: this walkthrough should only run once.
rm -f "$HOME/.config/wsl-setup-firstrun.zsh"
sed -i '/wsl-setup-firstrun\.zsh/d' "$HOME/.zshrc"
FIRSTRUN_EOF

# ---------- verify ----------
echo
echo -e "${GREEN}━━━ Verifying installation ━━━${NC}"

verify() {
  local name="$1" cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $name"
  else
    echo -e "  ${RED}✗${NC} $name (this is unexpected — check the log)"
  fi
}

verify "git"             "git --version"
verify "gh"              "gh --version"
verify "gh authenticated" "gh auth status"
verify "zsh"             "zsh --version"
verify "docker"          "docker --version"
verify "docker compose"  "docker compose version"
verify "mise"            "$HOME/.local/bin/mise --version"
verify "claude"          "command -v claude || [ -x $HOME/.local/bin/claude ]"
echo

# ---------- final message + restart ----------
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Setup complete! Restarting WSL...           ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo
echo "Why a restart? Two reasons:"
echo "  • Your default shell is now Zsh (active after restart)"
echo "  • Docker group membership activates after restart"
echo
echo "When this window closes, just open ${YELLOW}Ubuntu${NC} from your Start menu."
echo "A short walkthrough will guide you through the last few steps."
echo
echo "Log saved to: ${LOG_FILE}"
echo

for i in 5 4 3 2 1; do
  echo -ne "Restarting in ${i}... \r"
  sleep 1
done
echo

if command -v wsl.exe >/dev/null 2>&1; then
  wsl.exe --shutdown
else
  warn "Couldn't find wsl.exe to auto-restart."
  warn "From Windows PowerShell, run:  wsl --shutdown"
  warn "Then reopen Ubuntu from your Start menu."
fi
