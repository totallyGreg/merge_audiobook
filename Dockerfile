# Use a base image
FROM lscr.io/linuxserver/ffmpeg:latest

# Set working directory
WORKDIR /app

# Copy your script into the container at /app/
COPY merge_audiobook.sh /usr/local/bin/

# Make the script executable 
RUN chmod +x /usr/local/bin/merge_audiobook.sh

# Run your script
ENTRYPOINT ["/usr/local/bin/merge_audiobook.sh"]
