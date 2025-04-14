# Use a base image
# Stage 1: Build Stage
FROM lscr.io/linuxserver/ffmpeg:latest AS builder

# HACK: works but adds a ton to image
RUN apt-get update && apt-get install -y --no-install-recommends \
  bc && \
  # ... other dependencies ... && \
  rm -rf /var/lib/apt/lists/*

# Stage 2: Production Image
FROM lscr.io/linuxserver/ffmpeg:latest

WORKDIR /app

# Copy dependencies
COPY --from=builder /usr/bin/bc /usr/bin/

# Copy your script into the container at /app/

COPY merge_audiobook.sh /usr/local/bin/
# Set working directory
WORKDIR /app

# Make the script executable 
RUN chmod +x /usr/local/bin/merge_audiobook.sh

# Run your script
ENTRYPOINT ["/usr/local/bin/merge_audiobook.sh"]
