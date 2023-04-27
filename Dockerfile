# This Dockerfile is used to create a container image for a Ruby on Rails application.

# Define the base image for building the new image.
FROM ruby:2.7.7-slim-buster

# Define the argument variable RAILS_ROOT to be used later.
ARG RAILS_ROOT=/app

# Define the argument variable BUILD_PACKAGES with a list of packages that will be installed during image building.
ARG BUILD_PACKAGES="git tzdata openssh-server git build-essential default-libmysqlclient-dev nodejs unixodbc unixodbc-dev freetds-dev freetds-bin tdsodbc libpq-dev"

# Define the argument variable BUILD_PACKAGES_REMOVE with a list of packages that will be removed after installation.
ARG BUILD_PACKAGES_REMOVE="git bash openssh-server git build-essential nodejs openssh-server unixodbc unixodbc-dev freetds-dev freetds-bin tdsodbc libpq-dev"

# Define the environment variable RAILS_ENV as "staging" to inform Rails which execution environment to use.
ENV RAILS_ENV=staging

# Define the working directory for the RAILS_ROOT variable.
WORKDIR $RAILS_ROOT

# Update the base image packages and install the packages specified in the BUILD_PACKAGES variable.
RUN apt update \
    && apt install -yy $BUILD_PACKAGES

# Copy all files from the current directory to the image's working directory.
COPY . .

# Create the directory /root/.ssh/ inside the container.
RUN mkdir -p  /root/.ssh/

# Move the id_rsa file from the current directory to /root/.ssh/ inside the container.
RUN mv id_rsa  /root/.ssh/

# Change the permissions of the ~/.ssh directory to read-write by the owner only.
RUN chmod -R 0600 ~/.ssh

# Scan the Bitbucket.org key and add it to the known_hosts file inside the ~/.ssh directory.
RUN ssh-keyscan bitbucket.org >> githubKey && ssh-keygen -lf githubKey && cat githubKey >> ~/.ssh/known_hosts

# Install the Ruby on Rails project dependencies using the bundle install command.
RUN bundle install

# Remove the ~/.ssh directory from the container.
RUN rm -rf ~/.ssh

# Define the argument variables UID and GID to set the user and group IDs that will be created.
ARG UID=1000
ARG GID=1000

# Create a new group and a new user with the specified UID and GID.
RUN groupadd -g "${GID}" cbt \
  && useradd --create-home --no-log-init -u "${UID}" -g "${GID}" cbt

# Change the ownership and group of the working directory to the newly created user and group.
RUN chown -R cbt:cbt /app

# Set the entrypoint to /entrypoint.sh
# The entrypoint script is used to set environment variables, run database migrations, and start the Rails server.
USER cbt
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
