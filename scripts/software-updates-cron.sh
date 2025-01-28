#!/usr/bin/env zsh

# vim:filetype=zsh syntax=zsh tabstop=2 shiftwidth=2 softtabstop=2 expandtab autoindent fileencoding=utf-8

# These are commands that (based on the softwares installed), need to be periodically run to upgrade those softwares.
# Rather than remembering each tool and its specific command invocation, this script comes handy.

type load_zsh_configs &> /dev/null 2>&1 || source "${HOME}/.shellrc"
load_zsh_configs

if command_exists bupc; then
  section_header 'Running brew doctor'
  brew doctor
  section_header 'Updating brews'
  bupc
  success 'Successfully updated brews'
else
  debug 'skipping updating brews & casks'
fi

if command_exists mise; then
  section_header 'Updating mise'
  mise plugins update
  # This is typically run only in the ${HOME} folder so as to upgrade the software versions in the "global" sense
  mise upgrade --bump
  mise prune -y
  success 'Successfully updated mise plugins'
else
  debug 'skipping updating mise'
fi

if command_exists tldr; then
  section_header 'Updating tldr'
  tldr --update
  success 'Successfully updated tldr database'
else
  debug 'skipping updating tldr'
fi

if command_exists git-ignore-io; then
  section_header 'Updating git-ignore'
  # 'ignore-io' updates the data from http://gitignore.io so that we can generate the '.gitignore' file contents from the cmd-line
  git ignore-io --update-list
  success 'Successfully updated gitignore database'
else
  debug 'skipping updating git-ignore'
fi

if command_exists code; then
  section_header 'Updating VSCodium extensions'
  code --update-extensions
  success 'Successfully updated VSCodium extensions'
else
  debug 'skipping updating code extensions'
fi

if command_exists omz; then
  section_header 'Updating omz'
  omz update
  success 'Successfully updated oh-my-zsh'
else
  debug 'skipping updating omz'
fi

section_header 'Updating all browser profile chrome folders'
for folder in "${PERSONAL_PROFILES_DIR}"/*Profile/Profiles/DefaultProfile/chrome; do
  if is_git_repo "${folder}"; then
    git -C "${folder}" pull -r
    success "Successfully updated natsumi-browser into the folder: '$(yellow "${folder}")'"
  else
    debug "skipping updating '$(yellow "${folder}")' since it's not a git repo"
  fi
done
unset folder
