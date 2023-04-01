#!/bin/bash
CONTAINER_RUNTIME="docker"
USE_SUDO=""

if [[ "$(cat /etc/os-release | grep ID)" == *"suse"* ]]; then
  # SuSE-based
  PACKAGE_MANAGER="zypper"
elif [[ "$(cat /etc/os-release | grep ID)" == *"centos"* ]]; then
  # CentOS-based
  PACKAGE_MANAGER="rpm"
elif [[ "$(cat /etc/os-release | grep ID)" == *"debian"* ]]; then
  # Debian-based
  PACKAGE_MANAGER="apt-get"
fi

##Vars
#ECR
REGISTRY="cbt"
REGISTRY_ALIAS_NAME="public.ecr.aws/cbt"
REPOSITORY_NAME="ldap-agent"
IMAGE_NAME="ldap-agent"
AGENT_CONTAINER_NAME="cbt-agent"
AGENT_CMD="ldap-agent"
LDAP_REGISTER_CONTAINER_NAME="ldap-register"
LDAP_REGISTER_CMD="ldap-agent-register"
SQL_REGISTER_CONTAINER_NAME="sql-register"
SQL_REGISTER_CMD="sql-agent-register"
SCRIPT_INSTALLER_URL="https://raw.githubusercontent.com/coffeebeantech/cbt-agent-installer/master/cbt-agent.sh"
SCRIPT_NAME="cbt-agent"

if [ $(command -v jq) ]; then
  # Get the latest version from the ECR repository
  LATEST_VERSION=$(curl --silent 'https://api.us-east-1.gallery.ecr.aws/describeImageTags' --data-raw '{"registryAliasName":"'${REGISTRY}'","repositoryName":"'${REPOSITORY_NAME}'"}' --compressed | jq -r '.imageTagDetails[0].imageTag')
fi

# Define the environment variables LOG_DIR and CONFIG_DIR if they do not exist
: ${LOG_DIR:="/var/log/cbt-ldap-agent"}
: ${CONFIG_DIR:="/etc/cbt-ldap-agent"}
: ${LOG_DIR_SQL:="/var/log/cbt-ldap-agent-sql"}
: ${CONFIG_DIR_SQL:="/etc/cbt-ldap-agent-sql"}

function check_sudo() {
  if [ $(id -u) -ne 0 ]; then
    if [ $(command -v sudo) ]; then
      USE_SUDO="sudo"
      echo "This script requires administrator privileges to execute correctly. Please enter your sudo password to continue."
      sudo -v || { echo "sudo authentication failed. Please check your credentials and try again." ; exit 1; }
    else
      echo "This script requires administrator privileges or the installation of the sudo package to function correctly."
      exit 1
    fi
  fi
}

function download_cbt() {
  if [ ! -f "/usr/bin/$SCRIPT_NAME" ]; then
    echo "Downloading $SCRIPT_NAME script..."
    $USE_SUDO wget -q -O /usr/bin/$SCRIPT_NAME $SCRIPT_INSTALLER_URL
    $USE_SUDO chmod +x /usr/bin/$SCRIPT_NAME
    echo "$SCRIPT_NAME script downloaded successfully!"
  else
    read -p "$SCRIPT_NAME already exists. Would you like to update it? (Y/N) " confirmation < /dev/tty
    if [[ $confirmation =~ ^[Yy]$ ]]; then
      $USE_SUDO wget -q -O /usr/bin/$SCRIPT_NAME $SCRIPT_INSTALLER_URL
      $USE_SUDO chmod +x /usr/bin/$SCRIPT_NAME
      echo "$SCRIPT_NAME updated."
    else
      echo "Skipping..."
    fi
  fi
}

function install_jq() {
  if [[ "$PACKAGE_MANAGER" == "zypper" ]]; then
    # Install jq
    $USE_SUDO $PACKAGE_MANAGER --non-interactive install jq
  else
    curl -sSL -o /tmp/jq https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64 && chmod +x /tmp/jq
    $USE_SUDO mv /tmp/jq /usr/bin/
  fi
}

function restart_docker() {
  $USE_SUDO systemctl restart docker
  sleep 5
}

function install_docker() {
  # Add the current user to the 'docker' group so that it can run Docker commands without 'sudo' and start
  #$USE_SUDO usermod -aG docker $(whoami)
  if [[ "$PACKAGE_MANAGER" == "zypper" ]]; then
    $USE_SUDO $PACKAGE_MANAGER --non-interactive install docker
  else
    curl -fsSL https://get.docker.com | sudo bash -
  fi

  sleep 5
  restart_docker
  echo "Docker installed successfully"
  #echo "Unable to automatically install Docker on this system. Please refer to the Docker documentation for installation instructions."
  #exit 1
}

function check_jq() {
  if ! [ -x "$(command -v jq)" ]; then
    install_jq
  fi
}

function check_docker() {
  if ! [ -x "$(command -v $CONTAINER_RUNTIME)" ]; then
    install_docker
  else
    restart_docker
  fi
}

function pull_image() {
  check_jq
  check_docker

  if [ -z "$LATEST_VERSION" ]; then
    LATEST_VERSION=$(curl --silent 'https://api.us-east-1.gallery.ecr.aws/describeImageTags' --data-raw '{"registryAliasName":"'${REGISTRY}'","repositoryName":"'${REPOSITORY_NAME}'"}' --compressed | jq -r '.imageTagDetails[0].imageTag')
  fi

  # Check if image exist
  if $CONTAINER_RUNTIME images $REGISTRY_ALIAS_NAME/$REPOSITORY_NAME | grep -q $IMAGE_NAME; then
    echo "The $IMAGE_NAME image exists."

    # Check if the installed version is the latest
    INSTALLED_VERSION=$($CONTAINER_RUNTIME images --format "{{.Repository}}:{{.Tag}}" | grep $REPOSITORY_NAME | cut -d':' -f2)
    echo "The installed version of the $IMAGE_NAME image is: $INSTALLED_VERSION"

    if [ "$INSTALLED_VERSION" != "$LATEST_VERSION" ]; then
      echo "The installed version is not the latest version. Would you like to update to the latest version? (y/n)"
      read answer < /dev/tty
      if [ "$answer" =~ ^[Yy]$ ]; then
        echo "Updating to the latest version..."
        # Stop any running containers
        if $CONTAINER_RUNTIME ps -a | grep -q $AGENT_CONTAINER_NAME; then
          echo "Stopping any running containers..."
          $USE_SUDO $CONTAINER_RUNTIME stop $AGENT_CONTAINER_NAME
          $USE_SUDO $CONTAINER_RUNTIME rm -f $AGENT_CONTAINER_NAME > /dev/null 2>&1
        fi

        # Pull the latest version
        $USE_SUDO $CONTAINER_RUNTIME pull $REGISTRY_ALIAS_NAME/$REPOSITORY_NAME:$LATEST_VERSION
      else
        echo "Skipping update."
      fi
    else
      echo "The installed version is the latest version."
    fi

  else
    echo "The $IMAGE_NAME image does not exist. Pulling the latest version..."
    $USE_SUDO $CONTAINER_RUNTIME pull $REGISTRY_ALIAS_NAME/$REPOSITORY_NAME:$LATEST_VERSION
  fi
}

function service_configure_ldap() {
  if [[ -d "$LOG_DIR" ]] || [[ -d "$CONFIG_DIR" ]]; then
    read -p "The configuration and/or folders already exist. Do you want to delete the files and reconfigure? (Y/N) " delete_confirmation < /dev/tty
    if [[ $delete_confirmation =~ ^[Yy]$ ]]; then
      echo "Deleting existing configuration and folders..."
      $USE_SUDO rm -rf "$LOG_DIR"
      $USE_SUDO rm -rf "$CONFIG_DIR"
      $USE_SUDO $CONTAINER_RUNTIME rm -f $LDAP_REGISTER_CONTAINER_NAME > /dev/null 2>&1
      echo "Recreating configuration and folders..."
      $USE_SUDO mkdir -p "$LOG_DIR"
      $USE_SUDO mkdir -p "$CONFIG_DIR"
    else
      echo "Skipping configuration."
      return 0
    fi
  else
    echo "Creating configuration and folders..."
    $USE_SUDO mkdir -p "$LOG_DIR"
    $USE_SUDO mkdir -p "$CONFIG_DIR"
  fi

  # Configure the service
  echo "Configuring the $LDAP_REGISTER_CMD service..."

  $USE_SUDO $CONTAINER_RUNTIME run -it --name $LDAP_REGISTER_CONTAINER_NAME \
    -e LOG_DIR="$LOG_DIR" -e CONFIG_DIR="$CONFIG_DIR" \
    -v "$LOG_DIR:/var/log/cbt-ldap-agent" \
    -v "$CONFIG_DIR:/etc/cbt-ldap-agent" \
    $REGISTRY_ALIAS_NAME/$REPOSITORY_NAME:$LATEST_VERSION $LDAP_REGISTER_CMD
}

function service_configure_sql() {
  if [[ -d "$LOG_DIR_SQL" ]] || [[ -d "$CONFIG_DIR_SQL" ]]; then
    read -p "The configuration and/or folders already exist. Do you want to delete the files and reconfigure? (Y/N) " delete_confirmation < /dev/tty
    if [[ $delete_confirmation =~ ^[Yy]$ ]]; then
      echo "Deleting existing configuration and folders..."
      $USE_SUDO rm -rf "$LOG_DIR_SQL"
      $USE_SUDO rm -rf "$CONFIG_DIR_SQL"
      echo "Recreating configuration and folders..."
      $USE_SUDO mkdir -p "$LOG_DIR_SQL"
      $USE_SUDO mkdir -p "$CONFIG_DIR_SQL"
    else
      echo "Skipping configuration."
      return 0
    fi
  else
    echo "Creating configuration and folders..."
    $USE_SUDO mkdir -p "$LOG_DIR_SQL"
    $USE_SUDO mkdir -p "$CONFIG_DIR_SQL"
  fi

  # Configure the service
  echo "Configuring the $SQL_REGISTER_CMD service..."
  $USE_SUDO $CONTAINER_RUNTIME rm -f $SQL_REGISTER_CONTAINER_NAME >  /dev/null 2>&1
  $USE_SUDO $CONTAINER_RUNTIME run -it --name $SQL_REGISTER_CONTAINER_NAME \
    -e LOG_DIR="$LOG_DIR" -e CONFIG_DIR="$CONFIG_DIR" \
    -v "$LOG_DIR:/var/log/cbt-ldap-agent" \
    -v "$CONFIG_DIR:/etc/cbt-ldap-agent" \
    $REGISTRY_ALIAS_NAME/$REPOSITORY_NAME:$LATEST_VERSION $SQL_REGISTER_CMD
}

function service_cbt_run() {
  if $CONTAINER_RUNTIME images $REGISTRY_ALIAS_NAME/$REPOSITORY_NAME | grep -q $IMAGE_NAME; then
    if $USE_SUDO $CONTAINER_RUNTIME ps -a | grep -q $AGENT_CONTAINER_NAME; then
      read -p "The container already exists. Would you like to restart it? (Y/N) " confirmation < /dev/tty
      if [[ $confirmation =~ ^[Yy]$ ]]; then
        $USE_SUDO $CONTAINER_RUNTIME restart $AGENT_CONTAINER_NAME
        echo "Agent restarted successfully."
      else
        echo "Skipping..."
      fi
    else
      echo "$AGENT_CONTAINER_NAME container not found. Starting"
      $USE_SUDO $CONTAINER_RUNTIME run -it --name $AGENT_CONTAINER_NAME \
        -e LOG_DIR="$LOG_DIR" -e CONFIG_DIR="$CONFIG_DIR" \
        -v "$LOG_DIR:/var/log/cbt-ldap-agent" \
        -v "$CONFIG_DIR:/etc/cbt-ldap-agent" \
        $REGISTRY_ALIAS_NAME/$REPOSITORY_NAME:$LATEST_VERSION $AGENT_CMD
    fi
  else
    echo "Image not found. Please, pull image first."
  fi
}

function run_service_command() {
  local command="$USE_SUDO $CONTAINER_RUNTIME $1 $AGENT_CONTAINER_NAME"

  # Run the command and print the output
  echo "Running command: $command"
  eval "$command"
}

function service_options() {
  local option=$1

  # Set the appropriate command based on the option chosen
  case "$option" in
    "start")
      run_service_command "start"
      ;;
    "stop")
      run_service_command "stop"
      ;;
    "restart")
      run_service_command "restart"
      ;;
    "status")
      status=$(eval "$USE_SUDO $CONTAINER_RUNTIME ps -f name=$AGENT_CONTAINER_NAME")

      # Check if the container is running
      if [[ "$status" == *"$AGENT_CONTAINER_NAME"* ]]; then
        echo "====The service is running.===="
      else
        echo "====The service is not running.===="
        return 1
      fi
      ;;
    "logs")
      less +F $LOG_DIR/agent.log
      ;;
    *)
      echo "Invalid option, please choose a valid option."
      return 1
      ;;
  esac
}

function menu() {
  while true; do
    echo "==============="
    echo "Select an option:"
    echo "1 - Docker/image installation"
    echo "2 - LDAP configuration ($LDAP_REGISTER_CMD)"
    echo "3 - SQL configuration ($SQL_REGISTER_CMD)"
    echo "4 - Service execution ($AGENT_CMD)"
    echo "5 - Service management"
    echo "6 - Exit"
    read -p "Choose an option (1/2/3/4/5/6): " option < /dev/tty

    case "$option" in
      1)
        clear
        pull_image
        ;;
      2)
        clear
        service_configure_ldap
        ;;
      3)
        clear
        service_configure_sql
        ;;
      4)
        clear
        service_cbt_run
        ;;
      5)
        while true; do
          echo "==============="
          echo "Service management:"
          echo "1 - Start"
          echo "2 - Stop"
          echo "3 - Restart"
          echo "4 - Status"
          echo "5 - Logs"
          echo "6 - Back to main menu"
          read -p "Choose an option (1/2/3/4/5/6): " status_option < /dev/tty

          case "$status_option" in
            1)
              clear
              service_options "start"
              ;;
            2)
              clear
              service_options "stop"
              ;;
            3)
              clear
              service_options "restart"
              ;;
            4)
              clear
              service_options "status"
              ;;
            5)
              clear
              service_options "logs"
              ;;
            6)
              break
              ;;
            *)
              echo "Invalid option, please choose a valid option."
              ;;
          esac
        done
        ;;
      6)
        exit 0
        ;;
      *)
        echo "Invalid option, please choose a valid option."
        ;;
    esac
  done
}

check_sudo
download_cbt
menu
