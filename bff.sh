#!/bin/bash
#
# Version 12: fixed pagination of the shoutout stream
# Version 11: limit the depth of the blog mirroring (prevents infinite recursion on blogs with problems)
# Version 10: some textual changes and a better check for the login result
# Version 9: fix photo regex issue with older versions of GNU grep
# Version 8: grab all files for blogs.
# Version 7: show a warning that downloading a blog can take a LONG time
# Version 6: print a notice if the login has failed (but continue the download)
# Version 5: remove .incomplete for unavailable profiles
# Version 4: -- mistake
# Version 3: solves problem with album photos without a title
# Version 2: redo incomplete profiles 
# Version 1: last unversioned version
#
# Download a Friendster profile.
# ./friendster-scrape-profile PROFILE_ID [COOKIES_FILE]
#
# Currently downloads:
#  - the main profile page (profiles.friendster.com/$PROFILE_ID)
#  - the user's profile image from that page
#  - the list of public albums (www.friendster.com/viewalbums.php?uid=$PROFILE_ID)
#  - each of the album pages (www.friendster.com/viewphotos.php?a=$id&uid=$PROFILE_ID)
#  - the original photos from each album
#  - the list of friends (www.friendster.com/fans.php?uid=$PROFILE_ID)
#  - the other list of friends (www.friendster.com/fans.php?action=spusers&uid=$PROFILE_ID)
#  - the Friendster blog, if any
#
# Does not currently download anything else (such as the widgets on the profile page).
#
#
# BEFORE USE: enter your Friendster account data in username.txt and password.txt
#
#

PROFILE_ID=$1
COOKIES_FILE=$2
if [[ ! $COOKIES_FILE =~ .txt ]]
then
  COOKIES_FILE=cookies.txt
fi

USERNAME=`cat username.txt`
PASSWORD=`cat password.txt`
# trim whitespace
USERNAME=${USERNAME/ /}
PASSWORD=${PASSWORD/ /}

if [[ ! $USERNAME =~ @ ]]
then
  echo "Enter your username (your Friendster email) in username.txt and your password in password.txt."
  exit 3
fi

# check the id
if [[ ! $PROFILE_ID =~ ^[0-9]+$ ]]
then
  echo "No profile id given."
  exit 1
fi


START=$(date +%s)

# build directory name
PROFILE_ID_WITH_PREFIX=$PROFILE_ID
while [[ ${#PROFILE_ID_WITH_PREFIX} -lt 3 ]]
do
  # id too short, prefix with 0
  PROFILE_ID_WITH_PREFIX=0$PROFILE_ID_WITH_PREFIX
done
PROFILE_DIR=data/${PROFILE_ID_WITH_PREFIX:0:1}/${PROFILE_ID_WITH_PREFIX:1:1}/${PROFILE_ID_WITH_PREFIX:2:1}/$PROFILE_ID


USER_AGENT="Googlebot/2.1 (+http://www.googlebot.com/bot.html)"
WGET="wget --no-clobber -nv -a $PROFILE_DIR/wget.log"


# incomplete result from a previous run?
if [ -f $PROFILE_DIR/.incomplete ]
then
  echo "Deleting incomplete profile $PROFILE_ID..."
  rm -rf $PROFILE_DIR
fi


# user should not exist
if [ -d $PROFILE_DIR ]
then
  echo "Profile directory $PROFILE_DIR already exists. Not downloading."
  exit 2
fi


echo "Downloading $PROFILE_ID:"

# make directories
mkdir -p $PROFILE_DIR
mkdir -p $PROFILE_DIR/photos

# touch incomplete
touch $PROFILE_DIR/.incomplete


# make sure the cookies file exists (may be empty)
touch $COOKIES_FILE


# download profile page
echo " - profile page"
# reuse the session cookies, if there are any
$WGET -U "$USER_AGENT" --keep-session-cookies --save-cookies $COOKIES_FILE --load-cookies $COOKIES_FILE -O $PROFILE_DIR/profile.html "http://profiles.friendster.com/$PROFILE_ID"


# check if we are logged in, if not: do so
if ! grep -q "View, edit or update your profile" $PROFILE_DIR/profile.html
then
  echo "Logging in..."
  rm -f $COOKIES_FILE
  login_result_file=login_result_$$.html
  rm -f $login_result_file

  $WGET -U "$USER_AGENT" http://www.friendster.com/login.php -O $login_result_file --keep-session-cookies --save-cookies $COOKIES_FILE --load-cookies $COOKIES_FILE --post-data="_submitted=1&next=/&tzoffset=-120&email=$USERNAME&password=$PASSWORD"

  if grep -q "Log Out" $login_result_file
  then
    echo "Login successful."
  else
    echo "Login failed."
  fi

  rm -f $login_result_file
fi


# is this profile available?
if grep -q "This user's profile is not available." $PROFILE_DIR/profile.html
then
  echo "   Profile $PROFILE_ID not available."
  rm $PROFILE_DIR/.incomplete
  exit 5
fi


# extract profile url (with username)
profile_url=`cat $PROFILE_DIR/profile.html | grep -o -E "URL: </span><p><a href=\"http://profiles.friendster.com/.+\">http" | grep -o -E "http://profiles.friendster.com/[^\"]+"`
if [[ "$profile_url" =~ http:// ]]
then
  echo $profile_url > $PROFILE_DIR/profile_url.txt
fi

# extract blog url
blog_url=`cat $PROFILE_DIR/profile.html | grep -o -E "http://[^\"]+\.blogs?\.friendster\.com/" | uniq`
if [[ "$blog_url" =~ http:// ]]
then
  echo $blog_url > $PROFILE_DIR/blog_url.txt
fi

# download profile image
echo " - profile photo"
profile_photo_url=`grep -E "imgblock200.+img src=\".+m\.jpg\"" $PROFILE_DIR/profile.html | grep -o -E "src=\"http.+\.jpg" | grep -o -E "http.+"`
if [[ "$profile_photo_url" =~ "http://" ]]
then
  # url for original size
  photo_url_orig=${profile_photo_url/m.jpg/.jpg}
  # extract photo id
  photo_id=`expr "$profile_photo_url" : '.\+/photos/\(.\+\)m.jpg'`
  mkdir -p $PROFILE_DIR/photos/`dirname $photo_id`

  $WGET -U "$USER_AGENT" -O $PROFILE_DIR/photos/$photo_id.jpg "$photo_url_orig"

  cp $PROFILE_DIR/photos/$photo_id.jpg $PROFILE_DIR/profile_photo.jpg
fi

# download albums page
page=0
max_page=0
while [[ $page -le $max_page ]]
do
  echo " - albums index, page $page"
  $WGET -U "$USER_AGENT" -O $PROFILE_DIR/albums_${page}.html "http://www.friendster.com/viewalbums.php?uid=$PROFILE_ID&page=${page}"

  # get page links
  page_numbers=`grep -o -E "/viewalbums.php\?page=[0-9]+" $PROFILE_DIR/albums_${page}.html | grep -o -E "[0-9]+"`
  # update max page number
  for new_page_num in $page_numbers
  do
    if [[ $max_page -lt $new_page_num ]]
    then
      max_page=$new_page_num
    fi
  done

  # next page
  let "page = $page + 1"
done

# find album ids
ALBUM_IDS=`grep -o -E "/viewphotos\.php\?a=[0-9]+&amp;uid=" $PROFILE_DIR/albums_*.html | grep -o -E "[0-9]+" | sort | uniq`
for id in $ALBUM_IDS
do
  page=0
  max_page=0

  while [[ $page -le $max_page ]]
  do
    echo " - album $id, page $page"
    # download album page
    $WGET -U "$USER_AGENT" -O $PROFILE_DIR/photos_${id}_${page}.html "http://www.friendster.com/viewphotos.php?a=$id&uid=$PROFILE_ID&page=${page}"

    # get page links
    page_numbers=`grep -o -E "/viewphotos.php\?page=[0-9]+" $PROFILE_DIR/photos_${id}_${page}.html | grep -o -E "[0-9]+"`
    # update max page number
    for new_page_num in $page_numbers
    do
      if [[ $max_page -lt $new_page_num ]]
      then
        max_page=$new_page_num
      fi
    done

    # get photo urls
    PHOTO_URLS=`grep -o -E "http://photos[^\s]+friendster\.com/photos/[^\s]+m\.jpg" $PROFILE_DIR/photos_${id}_${page}.html | sort | uniq`

    # download photos
    for photo_url in $PHOTO_URLS
    do
      # url for original size
      photo_url_orig=${photo_url/m.jpg/.jpg}
      # extract photo id
      photo_id=`expr "$photo_url" : '.\+/photos/\(\S\+\)m.jpg'`
      mkdir -p $PROFILE_DIR/photos/`dirname $photo_id`

      $WGET -U "$USER_AGENT" -O $PROFILE_DIR/photos/$photo_id.jpg "$photo_url_orig"
    done

    # next page
    let "page = $page + 1"
  done
done

# download 'friends' page(s)
page=0
max_page=0
while [[ $page -le $max_page ]]
do
  echo " - friends page $page"
  # download page
  $WGET -U "$USER_AGENT" --max-redirect=0 -O $PROFILE_DIR/friends_${page}.html "http://www.friendster.com/friends.php?uid=$PROFILE_ID&page=${page}"

  # get page links
  page_numbers=`grep -o -E "/friends/$PROFILE_ID/[0-9]+\"" $PROFILE_DIR/friends_${page}.html | grep -o -E "[0-9]+\"" | grep -o -E "[0-9]+"`
  # update max page number
  for new_page_num in $page_numbers
  do
    if [[ $max_page -lt $new_page_num ]]
    then
      max_page=$new_page_num
    fi
  done

  let "page = $page + 1"
done

# download inverse 'friends' page(s)
page=0
max_page=0
while [[ $page -le $max_page ]]
do
  echo " - inverse friends page $page"
  # download page
  $WGET -U "$USER_AGENT" --max-redirect=0 -O $PROFILE_DIR/inverse_friends_${page}.html "http://www.friendster.com/friends.php?uid=$PROFILE_ID&page=${page}&action=spusers"

  # get page links
  page_numbers=`grep -o -E "/friends\.php\?page=[0-9]+" $PROFILE_DIR/inverse_friends_${page}.html | grep -o -E "[0-9]+"`
  # update max page number
  for new_page_num in $page_numbers
  do
    if [[ $max_page -lt $new_page_num ]]
    then
      max_page=$new_page_num
    fi
  done

  let "page = $page + 1"
done

# download 'fans' page(s)
page=0
max_page=0
while [[ $page -le $max_page ]]
do
  echo " - fans page $page"
  # download page
  $WGET -U "$USER_AGENT" --max-redirect=0 -O $PROFILE_DIR/fans_${page}.html "http://www.friendster.com/fans.php?uid=$PROFILE_ID&page=${page}"

  # get page links
  page_numbers=`grep -o -E "/fans/$PROFILE_ID/[0-9]+\"" $PROFILE_DIR/fans_${page}.html | grep -o -E "[0-9]+\"" | grep -o -E "[0-9]+"`
  # update max page number
  for new_page_num in $page_numbers
  do
    if [[ $max_page -lt $new_page_num ]]
    then
      max_page=$new_page_num
    fi
  done

  let "page = $page + 1"
done

# download inverse 'fans' page(s)
page=0
max_page=0
while [[ $page -le $max_page ]]
do
  echo " - inverse fans page $page"
  # download page
  $WGET -U "$USER_AGENT" --max-redirect=0 -O $PROFILE_DIR/inverse_fans_${page}.html "http://www.friendster.com/fans.php?uid=$PROFILE_ID&page=${page}&action=spusers"

  # get page links
  page_numbers=`grep -o -E "/fans\.php\?page=[0-9]+" $PROFILE_DIR/inverse_fans_${page}.html | grep -o -E "[0-9]+"`
  # update max page number
  for new_page_num in $page_numbers
  do
    if [[ $max_page -lt $new_page_num ]]
    then
      max_page=$new_page_num
    fi
  done

  let "page = $page + 1"
done

# download 'comments' page(s)
page=0
max_page=0
while [[ $page -le $max_page ]]
do
  echo " - comments page $page"
  # download page
  $WGET -U "$USER_AGENT" -O $PROFILE_DIR/comments_${page}.html "http://www.friendster.com/comments.php?uid=$PROFILE_ID&page=${page}" --keep-session-cookies --save-cookies $COOKIES_FILE --load-cookies $COOKIES_FILE

  # get page links
  page_numbers=`grep -o -E "/comments\.php\?page=[0-9]+" $PROFILE_DIR/comments_${page}.html | grep -o -E "[0-9]+"`
  # update max page number
  for new_page_num in $page_numbers
  do
    if [[ $max_page -lt $new_page_num ]]
    then
      max_page=$new_page_num
    fi
  done

  let "page = $page + 1"
done

# check the login box on the comments page
if ! grep -q "View, edit or update your profile" $PROFILE_DIR/comments_0.html
then
  echo ""
  echo "NOTE: It seems that you are not logged in."
  echo "      Most of a profile can be downloaded without a login,"
  echo "      but the Comments and Testimonials can not."
  echo "      Please check your username and password."
  echo ""
  echo "      (This script will continue, but you should really start again.)"
  echo ""

  touch $PROFILE_DIR/.without_login
fi

# download shoutout stream
page=1
shouts=0
number_of_shouts=1
while [[ $shouts -lt $number_of_shouts ]]
do
  echo " - shoutout stream $page"
  # download page
  $WGET -U "$USER_AGENT" -O $PROFILE_DIR/shoutout_${page}.html "http://www.friendster.com/shoutoutstream.php?uid=$PROFILE_ID&page=$page"

  number=`grep -o -E "totalShoutouts = [0-9]+" $PROFILE_DIR/shoutout_${page}.html | grep -o -E "[0-9]+"`
  if [[ $number_of_shouts -lt $number ]]
  then
    number_of_shouts=$number
  fi

  let "shouts = $shouts + 20"
  let "page = $page + 1"
done

# download shout comments, if any
SIDS=`grep -o -E "shoutoutstream\.php\?sid=[0-9]+&" $PROFILE_DIR/shoutout_*.html | grep -o -E "[0-9]+" | sort | uniq`
for sid in $SIDS
do
  echo " - shoutout comments for $sid"
  # download
  $WGET -U "$USER_AGENT" -O $PROFILE_DIR/shoutout_sid_$sid.html "http://www.friendster.com/shoutoutstream.php?sid=$sid&uid=$PROFILE_ID"

  # find even more comments
  authcode=`grep -o -E "var _ac = '[0-9a-z]+'" $PROFILE_DIR/shoutout_sid_$sid.html | grep -o -E "[0-9a-z]{10,}"`
  eid=$PROFILE_ID
  uid=$PROFILE_ID
  eeid=$sid
  last_page=`grep -o -E "currentCommentPage = [0-9]+" $PROFILE_DIR/shoutout_sid_$sid.html | grep -o -E "[0-9]+"`

  page=0
  while [[ $page -le $last_page ]]
  do
    $WGET -U "$USER_AGENT" -O $PROFILE_DIR/shoutout_sid_${sid}_comment_$page.json "http://www.friendster.com/rpc.php" --post-data="rpctype=fetchcomments&authcode=$authcode&page=$page&ct=5&eid=$eid&uid=$uid&eeid=$eeid"

    let "page = $page + 1"
  done
done

# check for a blog, if we haven't seen a link so far
if [[ ! "$blog_url" =~ http:// ]]
then
  $WGET -U "$USER_AGENT" -O $PROFILE_DIR/module_13.html "http://profiles.friendster.com/modules/module.php?uid=$PROFILE_ID&_pmr=&_pmmo=13"

  blog_url=`cat $PROFILE_DIR/module_13.html | grep -o -E "http://[^\"]+\.blogs?\.friendster\.com/" | uniq`
  if [[ "$blog_url" =~ http:// ]]
  then
    echo $blog_url > $PROFILE_DIR/blog_url.txt
  fi
fi

# download the blog, if it exists
if [[ "$blog_url" =~ http:// ]]
then
  # strip http:// and trailing slash
  blog_domain=${blog_url#http://}
  blog_domain=${blog_domain%/}

  blog_host=${blog_domain%.blogs.friendster.com}
  blog_host=${blog_host%.blog.friendster.com}

  mkdir -p $PROFILE_DIR/blog

  echo " - blog: $blog_url"
  echo "   (depending on the size of the blog, this can take a very long time)"
  wget --directory-prefix="$PROFILE_DIR/blog/" \
       -e robots=off \
       -a "$PROFILE_DIR/wget.log" \
       -nv -N -r -l 20 --no-remove-listing \
       -np -E -H -k -K -p \
       -U "$USER_AGENT" \
       -D "${blog_host}.blog.friendster.com,${blog_host}.blogs.friendster.com" \
       http://$blog_domain/
fi


# done
rm $PROFILE_DIR/.incomplete


END=$(date +%s)
DIFF=$(( $END - $START ))

echo " Profile $PROFILE_ID done. ($DIFF seconds)"
