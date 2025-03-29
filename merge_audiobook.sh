#!/bin/bash
set -e # Exit on error

# Check for input files
# NOTE: this currently assumes m4a/b audiofiles
if [ $# -lt 1 ]; then
  echo "Usage: $0 <file1.m4a> <file2.m4a> ..."
  exit 1
fi

# Create temporary directory
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
# trap 'export tmpdir; open $tmpdir' EXIT

# Initialize arrays
declare -a input_files=("$@")
declare -a durations
declare -a meta_files
declare -a cover_images

process_chapter_offset() {
  # Given a list of chapters in json and an offset in milliseconds
  # generate the new ffmetadata chapter information with new offset
  local meta_file="$1"
  local offset="$2"

  local chapter_data
  chapter_data=$(jq -r --argjson offset "$offset" '
        .chapters[] | 
        "[CHAPTER]\n" +
        "TIMEBASE=1/1000\n" +
        "START=\(.start + $offset)\n" +
        "END=\(.end + $offset)\n" +
        "title=\(.tags.title // "Untitled")\n"
    ' "$meta_file")

  printf "%s" "$chapter_data"
}

#
extract_cover() {
  local input_file="$1"
  local output_file="$2"
  ffmpeg -i "$input_file" -an -vcodec copy "$output_file" 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "Cover extracted: $output_file"
  else
    echo "No cover found in $input_file"
    return 1
  fi
}

add_cover_art() {
  if [ ${#cover_images[@]} -eq 0 ]; then
    echo "No cover images found. Skipping cover art addition."
  else
    mp4art --add "$tmpdir/cover_0.jpg" --preserve "$tmpdir/merged.m4a"
  fi
}

# Main loop
album=""
artist=""
cumulative_offset=0
chapters_file="$tmpdir/chapters.txt"

# Process each input file
# NOTE: I am assuming the first file has the correct values and ignoring the rest except chapter info
for i in "${!input_files[@]}"; do
  file="${input_files[$i]}"
  absolute_path=$(realpath "$file")
  echo "Processing $file..."

  # Create file list (with proper quoting)
  list_file="$tmpdir/list.txt"
  echo "file '$absolute_path'" >>"$list_file"

  # Extract metadata
  meta_file="$tmpdir/meta$i.json"
  ffprobe -v quiet -i "$file" -show_chapters -show_format -of json >"$meta_file"
  meta_files+=("$meta_file")

  # Get cover image
  # WARN: assuming jpg for convenience
  cover_image="$tmpdir/cover_$i.jpg"
  if extract_cover "$file" "$cover_image"; then
    cover_images+=("$cover_image")
  fi

  # Get file duration in milliseconds
  duration=$(jq -r '.format.duration' "$meta_file")
  duration_ms=$(echo "$duration * 1000" | bc | cut -d. -f1)

  # process_chapters
  # generate_chapter_ffmetadata "$meta_file" "$cumulative_offset" "$chapters_file"
  result=$(process_chapter_offset "$meta_file" "$cumulative_offset")
  printf "%s" "$result" >>"$chapters_file"

  # set offset to running total of duration_ms.  Duration array should calculate as equal
  cumulative_offset=$((cumulative_offset + duration_ms))
  durations+=("$duration_ms")

done

get_required_tags() {
  set -e
  local json_file="$1"
  shift
  local required_tags=("$@")

  # NOTE: eval is setting a variable for each tag that can be used later (i.e. artist)
  for tag in "${required_tags[@]}"; do
    value=$(jq -r ".format.tags.$tag // empty" "$json_file")
    if [ -n "$value" ]; then
      eval "${tag}=\"$value\""
      echo "$tag=${!tag}"
    else
      read -p "Enter value for $tag: " new_value
      eval "${tag}=\"$new_value\""
      echo "$tag=${!tag}"
    fi
  done
}

create_combined_metafile() {
  combined_meta="$tmpdir/metafile.txt"
  # Header and file creation
  echo ";FFMETADATA1" >"$combined_meta"
  # Global Metadata (year does not appear to be supported)
  get_required_tags "$tmpdir/meta0.json" "artist" "album" "album_artist" >>"$combined_meta"

  # [Stream] Metadata placeholder
  # [Chapter] Metadata
  cat "$chapters_file" >>"$combined_meta"
}

merge_audiobooks() {
  # Merge files and apply metadata
  # NOTE: `-movflags use_metadata_tags` doesn't seem to actually keep the global metadata
  # NOTE: testing composing the ffmpeg command in a function
  #
  # ffmpeg -loglevel error -hide_banner -f concat -safe 0 -i "$list_file" -i "$combined_meta" \
  #   -map_metadata 1 -map_chapters 1 -map 0:a -attach "${cover_images[0]}" -metadata:s:t:0 mimetype=image/jpeg \
  #   -movflags use_metadata_tags -c copy "$tmpdir/merged.m4a"

  echo "Merging files..."
  ffmpeg_cmd="ffmpeg -loglevel error -hide_banner -f concat -safe 0 -i \"$list_file\" -i \"$combined_meta\""

  # for cover in "${cover_images[@]}"; do
  #   ffmpeg_cmd+=" -i \"$cover\""
  # done

  ffmpeg_cmd+=" -map_metadata 1 -map_chapters 1 -map 0:a"

  # for i in "${!cover_images[@]}"; do
  #   ffmpeg_cmd+=" -attach \"${cover_images[$i]}\" -metadata:s:t:$i mimetype=image/jpeg"
  # done

  ffmpeg_cmd+=" -movflags use_metadata_tags -c copy \"$tmpdir/merged.m4a\""

  eval $ffmpeg_cmd
}

get_file_duration_in_ms() {
  local meta_file="$1"
  duration=$(ffprobe -v quiet -i "$meta_file" -show_format -of json | jq -r '.format.duration')
  duration_ms=$(echo "$duration * 1000" | bc | cut -d. -f1)
  echo "$duration_ms"
}

# Verify merged audiobook
verify_merged_file() {
  # compare final cumulative_offset to sum of durations which should be the same as final file duration
  #
  merged_duration=$(get_file_duration_in_ms "$tmpdir/merged.m4a")
  echo "Merged file duration is: $merged_duration"
  expected_duration=0
  for duration in "${durations[@]}"; do
    expected_duration=$((expected_duration + duration))
  done
  echo "Expected duration was: $expected_duration"

  if [ "$merged_duration" -eq "$expected_duration" ]; then
    echo "Duration verification passed"
  else
    echo "Warning: Merged file duration ($merged_duration ms) does not match sum of input durations ($expected_duration ms)"
    exit 1
  fi
}

create_combined_metafile
merge_audiobooks
# add_cover_art WARN: adding the cover art works, but apparently removes the artist and album tags from the file... shruggie
verify_merged_file

# Move final file to current directory
final_output="$artist-$album.m4b"
mv "$tmpdir/merged.m4a" "./$final_output"
mv "$combined_meta" .

echo "Successfully created: $final_output"
