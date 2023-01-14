#!/bin/bash

FLYWAY_VERSION=9.11.0-alpine

script_directory_absolute_path=$(cd $(dirname "${BASH_SOURCE:-$0}") && pwd)
project_root_absolute_path=$(dirname $(dirname $(dirname $(dirname "$script_directory_absolute_path"))))

valid_commands="baseline check clean info migrate repair snapshot undo validate"
valid_migration_targets="schema data"

usage="
Usage: ${BASH_SOURCE:-$0} [command] [migration target]\n
Valid commands: $valid_commands\n
Valid migration targets: $valid_migration_targets\n
"

if [ $# -ne 2 ]; then
  echo -e $usage
  exit 1
fi

echo $valid_commands | grep -qw $1
valid_command=$?

if [ $valid_command -ne 0 ]; then
  echo "ERROR: Unvalid command!"
  echo -e $usage
  exit 1
fi

echo $valid_migration_targets | grep -qw $2
valid_migration_target=$?

if [ $valid_migration_target -ne 0 ]; then
  echo "ERROR: Unvalid migration target!"
  echo -e $usage
  exit 1
fi

config_file_absolute_path=$script_directory_absolute_path
migration_scripts_location_absolute_path="$project_root_absolute_path/db/$2"
flyway_history_table="flyway_$2_history"

docker run --rm --name flyway -v $config_file_absolute_path:/flyway/conf -v $migration_scripts_location_absolute_path:/flyway/sql flyway/flyway:$FLYWAY_VERSION -table=$flyway_history_table $1
