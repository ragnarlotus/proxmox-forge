#!/bin/bash
# F238: inspect or safely fast-forward the agreed Forge Git checkout.
# The Forge CLI owns the global lock; this helper never updates host/guests.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: Forge runtime guard is unavailable\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 3 ]] || fail "usage: self-update.sh check|update REPOSITORY BRANCH"
mode="$1"
repo="$2"
branch="$3"
[[ "$mode" == check || "$mode" == update ]] || fail "invalid self-update mode"
[[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail "invalid Git branch '$branch'"
command -v git >/dev/null 2>&1 || fail "Git is unavailable"
git check-ref-format --branch "$branch" >/dev/null 2>&1 || fail "invalid Git branch '$branch'"

repo="$(cd "$repo" && pwd -P)" || fail "Forge checkout is unavailable"
top="$(git -C "$repo" rev-parse --show-toplevel)" || fail "Forge checkout is not a Git repository"
[[ "$(cd "$top" && pwd -P)" == "$repo" ]] ||
  fail "Forge must run from the root of its own Git checkout"
[[ -f "$repo/forge" && -f "$repo/forge.conf.default" ]] ||
  fail "repository does not contain the Forge entrypoint/configuration"

current_branch="$(git -C "$repo" symbolic-ref --quiet --short HEAD)" ||
  fail "Forge checkout has a detached HEAD"
current_sha="$(git -C "$repo" rev-parse --verify HEAD)" ||
  fail "cannot read current Forge commit"

remote="$(git -C "$repo" config --get "branch.$current_branch.remote")" ||
  fail "current Forge branch '$current_branch' has no configured remote"
[[ -n "$remote" && "$remote" != . ]] || fail "invalid Forge remote"
remote_url="$(git -C "$repo" remote get-url "$remote")" ||
  fail "cannot resolve configured Forge remote '$remote'"
# The local checkout has historically used an SSH alias named github-proxmox-forge.
case "$remote_url" in
  git@github.com:ragnarlotus/proxmox-forge|\
  git@github.com:ragnarlotus/proxmox-forge.git|\
  git@github-proxmox-forge:ragnarlotus/proxmox-forge|\
  git@github-proxmox-forge:ragnarlotus/proxmox-forge.git|\
  github-proxmox-forge:ragnarlotus/proxmox-forge|\
  github-proxmox-forge:ragnarlotus/proxmox-forge.git|\
  ssh://git@github.com/ragnarlotus/proxmox-forge|\
  ssh://git@github.com/ragnarlotus/proxmox-forge.git|\
  ssh://git@github-proxmox-forge/ragnarlotus/proxmox-forge|\
  ssh://git@github-proxmox-forge/ragnarlotus/proxmox-forge.git|\
  https://github.com/ragnarlotus/proxmox-forge|\
  https://github.com/ragnarlotus/proxmox-forge.git)
    ;;
  *) fail "configured Forge remote is not the approved ragnarlotus/proxmox-forge repository" ;;
esac

# Refuse modified/staged tracked files, but leave untracked and ignored
# host-local files alone. Git already protects ordinary untracked files from
# checkout collisions; ignored files need explicit protection (git merge may
# otherwise overwrite them when the upstream branch starts tracking that path).
if [[ -n "$(git -C "$repo" status --porcelain=v1 --untracked-files=no)" ]]; then
  fail "Forge checkout contains changes to tracked files; update manually after reviewing them"
fi

# Fetch exactly the requested branch, without touching the worktree or tags.
remote_ref="refs/remotes/$remote/$branch"
git -C "$repo" fetch --quiet --no-tags "$remote" \
  "refs/heads/$branch:$remote_ref" ||
  fail "cannot fetch Forge branch '$branch' from '$remote'"
remote_sha="$(git -C "$repo" rev-parse --verify "$remote_ref^{commit}")" ||
  fail "Forge remote branch '$branch' does not resolve to a commit"

# Explicit branch switches are allowed only when they preserve the current
# checked-out commit: no rollback, history rewrite or unrelated branch switch.
git -C "$repo" merge-base --is-ancestor "$current_sha" "$remote_sha" ||
  fail "branch '$branch' is divergent or older; refusing non-fast-forward update"
if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
  local_sha="$(git -C "$repo" rev-parse --verify "refs/heads/$branch")" ||
    fail "cannot resolve local branch '$branch'"
  git -C "$repo" merge-base --is-ancestor "$local_sha" "$remote_sha" ||
    fail "local branch '$branch' is divergent; refusing to overwrite it"
fi

if [[ "$mode" == check ]]; then
  if [[ "$current_sha" == "$remote_sha" && "$current_branch" == "$branch" ]]; then
    printf 'self_update=up_to_date branch=%s current=%s\n' "$branch" "$current_sha"
  else
    printf 'self_update=available branch=%s current=%s remote=%s\n' \
      "$branch" "$current_sha" "$remote_sha"
  fi
  exit 0
fi

# An upstream addition must never replace a host-local file, including an
# ignored file (e.g. forge.conf). For an unchanged tracked checkout, any path
# newly tracked by the requested revision that already exists locally is a
# collision. Preserve it and fail without switching branches or merging.
incoming_paths_file="$(mktemp)" || fail "cannot create temporary path inventory"
trap 'rm -f -- "$incoming_paths_file"' EXIT
git -C "$repo" diff --name-only --diff-filter=A -z "$current_sha" "$remote_sha" > "$incoming_paths_file" ||
  fail "cannot inspect paths added by Forge update"
while IFS= read -r -d '' incoming_path; do
  if [[ -e "$repo/$incoming_path" || -L "$repo/$incoming_path" ]]; then
    fail "Forge update would overwrite local untracked or ignored file: $incoming_path"
  fi
done < "$incoming_paths_file"
rm -f -- "$incoming_paths_file" || fail "cannot remove temporary path inventory"
trap - EXIT

if [[ "$current_branch" != "$branch" ]]; then
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo" switch --quiet "$branch" ||
      fail "cannot switch to existing Forge branch '$branch'"
  else
    git -C "$repo" switch --quiet --track -c "$branch" "$remote_ref" ||
      fail "cannot create tracking Forge branch '$branch'"
  fi
fi

# For a newly-created tracking branch this is already up to date.
git -C "$repo" merge --ff-only --quiet "$remote_ref" ||
  fail "Forge fast-forward failed; inspect checkout before updating systems"
final_sha="$(git -C "$repo" rev-parse --verify HEAD)" ||
  fail "cannot verify final Forge revision"
[[ "$final_sha" == "$remote_sha" ]] ||
  fail "Forge revision after update does not match requested remote branch"
printf 'self_update=success branch=%s previous=%s current=%s\n' \
  "$branch" "$current_sha" "$final_sha"
