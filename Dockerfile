# Use a base image
FROM lscr.io/linuxserver/ffmpeg:latest

# Set working directory
WORKDIR /app

# Copy your script into the container at /app/
COPY ./merge_audiobook.sh /app/

# Make the script executable 
RUN chmod +x /app/merge_audiobook.sh

# Optional: Install any missing dependencies (if needed)
# RUN apt-get update && apt-get install -y --no-install-recommends <missing_dependencies>

# Run your script
CMD ["/app/merge_audiobook.sh"]
