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
# Get the latest version from the ECR repository
LATEST_VERSION=$(curl --silent 'https://api.us-east-1.gallery.ecr.aws/describeImageTags' --data-raw '{"registryAliasName":"'${REGISTRY}'","repositoryName":"'${REPOSITORY_NAME}'"}' --compressed | jq -r '.imageTagDetails[0].imageTag')
echo "The latest version of the ldap-agent image is: $LATEST_VERSION"

# Define the environment variables LOG_DIR and CONFIG_DIR if they do not exist
: ${LOG_DIR:="/var/log/cbt-ldap-agent"}
: ${CONFIG_DIR:="/etc/cbt-ldap-agent"}
: ${LOG_DIR_SQL:="/var/log/cbt-ldap-agent-sql"}
: ${CONFIG_DIR_SQL:="/etc/cbt-ldap-agent-sql"}

function check_sudo() {
    if [ $(id -u) -ne 0 ] && [ ! $(command -v sudo) ]; then
        echo "This script requires administrator privileges or the installation of the sudo package to function correctly."
        exit 1
    else
        if [ $(command -v sudo) ]; then
            USE_SUDO="sudo"
        fi
    fi

    if [ $(command -v sudo) ]; then
        echo "This script requires administrator privileges to execute correctly. Please enter your sudo password to continue."
        sudo -v || { echo "sudo authentication failed. Please check your credentials and try again." ; exit 1; }
    fi
}


function download_cbt() {
    if [ ! -f "/usr/bin/cbt-installer" ]; then
        echo "Downloading cbt-installer script..."
        $USE_SUDO wget -q -O /usr/bin/cbt-installer https://raw.githubusercontent.com/coffeebeantech/cbt-agent-installer/master/cbt-agent.sh
	$USE_SUDO chmod +x /usr/bin/cbt-installer
        echo "cbt-installer script downloaded successfully!"
    else
        read -p "cbt-instaler already exists. Would you like to update it? (Y/N) " confirmation
        if [[ $confirmation =~ ^[Yy]$ ]]; then
                $USE_SUDO wget -q -O /usr/bin/cbt-installer https://raw.githubusercontent.com/coffeebeantech/cbt-agent-installer/master/cbt-agent.sh
		$USE_SUDO chmod +x /usr/bin/cbt-installer
                echo "cbt-installer updated."
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

function install_docker() {
  if [[ "$PACKAGE_MANAGER" == "zypper" ]]; then
    $USE_SUDO $PACKAGE_MANAGER --non-interactive install docker 
    # Add the current user to the 'docker' group so that it can run Docker commands without 'sudo' and start
    #$USE_SUDO usermod -aG docker $(whoami)
    sleep 5
    $USE_SUDO systemctl restart docker
    sleep 5
    echo "Docker installed successfully"
  else
    curl -fsSL https://get.docker.com | sudo bash -
    # Add the current user to the 'docker' group so that it can run Docker commands without 'sudo' and start
    #$USE_SUDO  usermod -aG docker $(whoami)
    sleep 5
    $USE_SUDO systemctl restart docker
    sleep 5
    echo "Docker installed successfully"
    #echo "Unable to automatically install Docker on this system. Please refer to the Docker documentation for installation instructions."
    #exit 1
  fi
}

function check_jq() {
  if ! [ -x "$(command -v jq)" ]; then
    install_jq
  fi
}

function check_docker() {
  if ! [ -x "$(command -v $CONTAINER_RUNTIME)" ]; then
    install_docker
  fi
}

function pull_image() {
  check_jq
  check_docker
  # Check if any ldap-agent images exist
  if $CONTAINER_RUNTIME images $REGISTRY_ALIAS_NAME/$REPOSITORY_NAME | grep -q ldap-agent; then
    echo "The ldap-agent image exists."

    # Check if the installed version is the latest
    INSTALLED_VERSION=$($CONTAINER_RUNTIME images --format "{{.Repository}}:{{.Tag}}" | grep $REPOSITORY_NAME | cut -d':' -f2)
    echo "The installed version of the ldap-agent image is: $INSTALLED_VERSION"

    if [ "$INSTALLED_VERSION" != "$LATEST_VERSION" ]; then
      echo "The installed version is not the latest version. Would you like to update to the latest version? (y/n)"
      read answer
      if [ "$answer" =~ ^[Yy]$ ]; then
        echo "Updating to the latest version..."
        # Stop any running containers
        if $CONTAINER_RUNTIME ps -a | grep -q ldap-agent; then
          echo "Stopping any running containers..."
          $USE_SUDO $CONTAINER_RUNTIME stop ldap-agent
          $USE_SUDO $CONTAINER_RUNTIME rm -f ldap-agent > /dev/null 2>&1
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
    echo "The ldap-agent image does not exist. Pulling the latest version..."
    $USE_SUDO $CONTAINER_RUNTIME pull $REGISTRY_ALIAS_NAME/$REPOSITORY_NAME:$LATEST_VERSION
  fi
}

function service_configure_ldap() {
  if [[ -d "$LOG_DIR" ]] || [[ -d "$CONFIG_DIR" ]]; then
    read -p "The configuration and/or folders already exist. Do you want to delete the files and reconfigure? (Y/N) " delete_confirmation
    if [[ $delete_confirmation =~ ^[Yy]$ ]]; then
      echo "Deleting existing configuration and folders..."
      $USE_SUDO rm -rf "$LOG_DIR"
      $USE_SUDO rm -rf "$CONFIG_DIR"
      $USE_SUDO $CONTAINER_RUNTIME rm -f ldap-agent-register > /dev/null 2>&1
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
  echo "Configuring the ldap-agent service..."

  $USE_SUDO $CONTAINER_RUNTIME run -it --name ldap-agent-register \
    -e LOG_DIR="$LOG_DIR" -e CONFIG_DIR="$CONFIG_DIR" \
    -v "$LOG_DIR:/var/log/cbt-ldap-agent" \
    -v "$CONFIG_DIR:/etc/cbt-ldap-agent" \
    $REGISTRY_ALIAS_NAME/$REPOSITORY_NAME:$LATEST_VERSION ldap-agent-register 

}

function service_configure_sql() {
  if [[ -d "$LOG_DIR_SQL" ]] || [[ -d "$CONFIG_DIR_SQL" ]]; then
    read -p "The configuration and/or folders already exist. Do you want to delete the files and reconfigure? (Y/N) " delete_confirmation
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
  echo "Configuring the ldap-agent-sql service..."
  $USE_SUDO $CONTAINER_RUNTIME rm -f ldap-agent-register-sql >  /dev/null 2>&1
  $USE_SUDO $CONTAINER_RUNTIME run -it --name ldap-agent-register-sql \
    -e LOG_DIR="$LOG_DIR" -e CONFIG_DIR="$CONFIG_DIR" \
    -v "$LOG_DIR:/var/log/cbt-ldap-agent" \
    -v "$CONFIG_DIR:/etc/cbt-ldap-agent" \
    $REGISTRY_ALIAS_NAME/$REPOSITORY_NAME:$LATEST_VERSION ldap-agent-register-sql 
}


function service_cbt_run() {
  if $CONTAINER_RUNTIME images $REGISTRY_ALIAS_NAME/$REPOSITORY_NAME | grep -q ldap-agent; then
    if $USE_SUDO $CONTAINER_RUNTIME ps -a | grep -q "ldap-agent"; then
      read -p "The container is already exists. Would you like to restart it? (Y/N) " confirmation
      if [[ $confirmation =~ ^[Yy]$ ]]; then  
        $USE_SUDO $CONTAINER_RUNTIME restart ldap-agent
        echo "Agent restarted successfully."
      else
        echo "Skipping..."
      fi
      else
        echo "The ldap-agent container not found. Starting"
        $USE_SUDO $CONTAINER_RUNTIME run -it --name ldap-agent \
          -e LOG_DIR="$LOG_DIR" -e CONFIG_DIR="$CONFIG_DIR" \
          -v "$LOG_DIR:/var/log/cbt-ldap-agent" \
          -v "$CONFIG_DIR:/etc/cbt-ldap-agent" \
          $REGISTRY_ALIAS_NAME/$REPOSITORY_NAME:$LATEST_VERSION ldap-agent
      fi
  else
    echo "Image not found. Please, pull image first."
  fi
}

function service_options() {
  local option=$1

  # Set the appropriate command based on the option chosen
  case "$option" in
    "start")
      command="$USE_SUDO $CONTAINER_RUNTIME start ldap-agent"
      ;;
    "stop")
      command="$USE_SUDO $CONTAINER_RUNTIME stop ldap-agent"
      ;;
    "restart")
      command="$USE_SUDO $CONTAINER_RUNTIME restart ldap-agent"
      ;;
    "status")
      status=$(eval "$USE_SUDO $CONTAINER_RUNTIME ps -f name=ldap-agent")

      # Check if the container is running
      if [[ "$status" == *"ldap-agent"* ]]; then
        echo "====The service is running.===="
      else
        echo "====The service is not running.===="
        return 1
      fi
      ;;
    *)
      echo "Invalid option, please choose a valid option."
      return 1
      ;;
  esac

  # Run the command and print the output
  echo "Running command: $command"
  eval "$command"
}


check_sudo
download_cbt
while true; do
  echo "==============="
  echo "Select an option:"
  echo "1 - Docker/image installation"
  echo "2 - LDAP configuration (ldap-agent-register)"
  echo "3 - SQL configuration (sql-agent-register)"
  echo "4 - Service execution (cbt-agent)"
  echo "5 - Service status"
  echo "6 - Uninstall service"
  echo "7 - Exit"
  read -p "Choose an option (1/2/3/4/5/6/7): " option

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
        echo "Service status:"
        echo "1 - Start"
        echo "2 - Stop"
        echo "3 - Restart"
        echo "4 - Status"
        echo "5 - Back to main menu"
        read -p "Choose an option (1/2/3/4/5): " status_option

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
            break
            ;;
          *)
            echo "Invalid option, please choose a valid option."
            ;;
        esac
      done
      ;;
    6)
      clear
      uninstall_service
      ;;
    7)
      exit 0
      ;;
    *)
      echo "Invalid option, please choose a valid option."
      ;;
  esac
done
