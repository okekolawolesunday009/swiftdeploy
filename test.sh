#!/usr/bin/env bash


COMMAND=$1
ARG=$2

case $COMMAND in
  greet)
    echo "Hello, $ARG!"
    ;;
  farewell)
    echo "Goodbye, $ARG!"
    ;;
  *)
    echo "Unknown command: $COMMAND"
    ;;
esac