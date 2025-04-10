# Use a base image
FROM lscr.io/linuxserver/ffmpeg:latest

# HACK: works but adds a ton to image
RUN apt-get update && apt-get install -y --no-install-recommends \
  ffmpeg \
  bc && \
  # ... other dependencies ... && \
  rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy your script into the container at /app/
COPY merge_audiobook.sh /usr/local/bin/

# Make the script executable 
RUN chmod +x /usr/local/bin/merge_audiobook.sh

# Run your script
ENTRYPOINT ["/usr/local/bin/merge_audiobook.sh"]
