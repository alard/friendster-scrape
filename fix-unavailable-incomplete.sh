#!/bin/bash
#
# Version 3 and earlier of the bff.sh script did not remove
# the .incomplete from the directory of unavailable profiles.
#
# Run this script (in the same directory as bff.sh) to remove
# these spurious .incomplete files.
#

find data -name '.incomplete' |
while read i
do
  dir=`dirname $i`
  if [[ -f $dir/profile.html ]]
  then
    # check for unavailability
    if grep -q "This user's profile is not available." $dir/profile.html
    then
      echo "Removing $dir/.incomplete"
      rm $dir/.incomplete
    fi
  fi
done

