/*
 *  osbf_aux.c 
 *  
 *  This software is licensed to the public under the Free Software
 *  Foundation's GNU GPL, version 2.  You may obtain a copy of the
 *  GPL by visiting the Free Software Foundations web site at
 *  www.fsf.org, and a copy is included in this distribution.  
 *
 * Copyright 2005, 2006, 2007 Fidelis Assis, all rights reserved.
 * Copyright 2005, 2006, 2007 Williams Yerazunis, all rights reserved.
 *
 * Read the HISTORY_AND_AGREEMENT for details.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <errno.h>

#include "osbflib.h"

#define BUCKET_BUFFER_SIZE 5000

/* Version names */
const char *db_version_names[] = {
  "SBPH-Markovian",
  "OSB-Bayes",
  "Correlate",
  "Neural",
  "OSB-Winnow",
  "OSBF-Bayes",
  "Unknown"
};

uint32_t microgroom_chain_length = OSBF_MICROGROOM_CHAIN_LENGTH;
uint32_t microgroom_stop_after = OSBF_MICROGROOM_STOP_AFTER;

/*****************************************************************/

/*
 * Pack a chain moving buckets to a place closer to their
 * right positions whenever possible, using the buckets marked as free.
 * At the end, all buckets still marked as free are zeroed.
 */
void
osbf_packchain (CLASS_STRUCT * class, uint32_t packstart, uint32_t packlen)
{
  uint32_t packend, ifrom, ito, free_start;
  uint32_t thash;

  packend = packstart + packlen;
  if (packend >= NUM_BUCKETS (class))
    packend -= NUM_BUCKETS (class);

#ifdef DEBUG_packchain
  {
    uint32_t i, rp, d, h;
    fprintf (stderr, "Before packing\n");
    for (i = packstart; i != packend; i = NEXT_BUCKET (class, i))
      {
	h = BUCKET_HASH (class, i);
	rp = HASH_INDEX (class, h);
	if (i >= rp)
	  d = i - rp;
	else
	  d = NUM_BUCKETS (class) + i - rp;
	fprintf (stderr, " i: %5" PRIu32 " d: %3" PRIu32 " value: %" PRIu32
		 " h: %08X flags: %02X\n", i, d, BUCKET_VALUE (class, i),
		 h, BUCKET_FLAGS (class, i));
      }
  }
#endif

  /* search the first marked-free bucket */
  for (free_start = packstart;
       free_start != packend; free_start = NEXT_BUCKET (class, free_start))
    if (MARKED_FREE (class, free_start))
      break;

  if (free_start != packend)
    {
      for (ifrom = NEXT_BUCKET (class, free_start);
	   ifrom != packend; ifrom = NEXT_BUCKET (class, ifrom))
	{
	  if (!MARKED_FREE (class, ifrom))
	    {
	      /* see if there's a free bucket closer to its right place */
	      thash = BUCKET_HASH (class, ifrom);
	      ito = HASH_INDEX (class, thash);

	      while (ito != ifrom && !MARKED_FREE (class, ito))
		ito = NEXT_BUCKET (class, ito);

	      /* if found a marked-free bucket, use it */
	      if (MARKED_FREE (class, ito))
		{
		  /* copy bucket and flags */
		  BUCKET_HASH (class, ito) = thash;
		  BUCKET_KEY (class, ito) = BUCKET_KEY (class, ifrom);
		  BUCKET_VALUE (class, ito) = BUCKET_VALUE (class, ifrom);
		  BUCKET_FLAGS (class, ito) = BUCKET_FLAGS (class, ifrom);
		  /* mark the from bucket as free */
		  MARK_IT_FREE (class, ifrom);
		}
	    }
	}
    }

#ifdef DEBUG_packchain
  {
    uint32_t i, rp, d, h;
    fprintf (stderr, "Before zeroing\n");
    for (i = packstart; i != packend; i = NEXT_BUCKET (class, i))
      {
	h = BUCKET_HASH (class, i);
	rp = HASH_INDEX (class, h);
	if (i >= rp)
	  d = i - rp;
	else
	  d = NUM_BUCKETS (class) + i - rp;
	fprintf (stderr, " i: %5" PRIu32 " d: %3" PRIu32 " value: %" PRIu32
		 " h: %08X flags: %02X\n", i, d, BUCKET_VALUE (class, i),
		 h, BUCKET_FLAGS (class, i));
      }
  }
#endif

  for (ito = packstart; ito != packend; ito = NEXT_BUCKET (class, ito))
    if (MARKED_FREE (class, ito))
      {
	BUCKET_VALUE (class, ito) = 0;
	UNMARK_IT_FREE (class, ito);
      }

#ifdef DEBUG_packchain
  {
    uint32_t i, rp, d, h;
    fprintf (stderr, "After packing\n");
    for (i = packstart; i != packend; i = NEXT_BUCKET (class, i))
      {
	h = BUCKET_HASH (class, i);
	rp = HASH_INDEX (class, h);
	if (i >= rp)
	  d = i - rp;
	else
	  d = NUM_BUCKETS (class) + i - rp;
	fprintf (stderr, " i: %5" PRIu32 " d: %3" PRIu32 " value: %" PRIu32
		 " h: %08X flags: %02X\n", i, d, BUCKET_VALUE (class, i),
		 h, BUCKET_FLAGS (class, i));
      }
  }
#endif

}

/*****************************************************************/

/*
 * Prune and pack a chain in a class database
 * Returns the number of freed (zeroed) buckets
 */
uint32_t
osbf_microgroom (CLASS_STRUCT * class, uint32_t bindex)
{
  uint32_t i_aux, j_aux, right_position;
  static uint32_t microgroom_count = 0;
  uint32_t packstart, packlen;
  uint32_t zeroed_countdown, min_value, min_value_any;
  uint32_t distance, max_distance;
  uint32_t groom_locked = OSBF_MICROGROOM_LOCKED;

  j_aux = 0;
  zeroed_countdown = microgroom_stop_after;

  i_aux = j_aux = 0;
  microgroom_count++;

  /*  move to start of chain that overflowed,
   *  then prune just that chain.
   */
  min_value = OSBF_MAX_BUCKET_VALUE;
  i_aux = j_aux = HASH_INDEX (class, bindex);
  min_value_any = BUCKET_VALUE (class, i_aux);

  if (!BUCKET_IN_CHAIN (class, i_aux))
    return 0;			/* initial bucket not in a chain! */

  while (BUCKET_IN_CHAIN (class, i_aux))
    {
      if (BUCKET_VALUE (class, i_aux) < min_value_any)
	min_value_any = BUCKET_VALUE (class, i_aux);
      if (BUCKET_VALUE (class, i_aux) < min_value &&
	  !BUCKET_IS_LOCKED (class, i_aux))
	min_value = BUCKET_VALUE (class, i_aux);
      i_aux = PREV_BUCKET (class, i_aux);
      if (i_aux == j_aux)
	break;			/* don't hang if we have a 100% full .css file */
      /* fprintf (stderr, "-"); */
    }

  /*  now, move the index to the first bucket in this chain. */
  i_aux = NEXT_BUCKET (class, i_aux);
  packstart = i_aux;
  /* find the end of the chain */
  while (BUCKET_IN_CHAIN (class, i_aux))
    {
      i_aux = NEXT_BUCKET (class, i_aux);
      if (i_aux == packstart)
	break;			/* don't hang if we have a 100% full .cfc file */
    }
  /*  now, the index is right after the last bucket in this chain. */

  /* only >, not >= in this case, otherwise the packlen would be 0
   * instead of NUM_BUCKETS (class).
   */
  if (i_aux > packstart)
    packlen = i_aux - packstart;
  else				/* if i_aux == packstart, packlen = header->buckets */
    packlen = NUM_BUCKETS (class) + i_aux - packstart;

  /* if no unlocked bucket can be zeroed, zero any */
  if (groom_locked > 0 || min_value == OSBF_MAX_BUCKET_VALUE)
    {
      groom_locked = 1;
      min_value = min_value_any;
    }
  else
    groom_locked = 0;

/*
 *   This pruning method zeroes buckets with minimum count in the chain.
 *   It tries first buckets with minimum distance to their right position,
 *   to increase the chance of zeroing older buckets first. If none with
 *   distance 0 is found, the distance is increased until at least one
 *   bucket is zeroed.
 *
 *   We keep track of how many buckets we've marked to be zeroed and we
 *   stop marking additional buckets after that point. That messes up
 *   the tail length, and if we don't repack the tail, then features in
 *   the tail can become permanently inaccessible! Therefore, we really
 *   can't stop in the middle of the tail (well, we could stop marking,
 *   but we need to pass the full length of the tail in).
 * 
 *   This is a statistics report of microgroomings for 4147 messages
 *   of the SpamAssassin corpus. It shows that 77% is done in a single
 *   pass, 95.2% in 1 or 2 passes and 99% in at most 3 passes.
 *
 *   # microgrommings   passes   %    accum. %
 *        232584           1    76.6   76.6
 *         56396           2    18.6   95.2
 *         11172           3     3.7   98.9
 *          2502           4     0.8   99.7
 *           726           5     0.2   99.9
 *           ...
 *   -----------
 *        303773
 *
 *   If we consider only the last 100 microgroomings, when the cfc
 *   file is full, we'll have the following numbers showing that most
 *   microgroomings (61%) are still done in a single pass, almost 90%
 *   is done in 1 or 2 passes and 97% are done in at most 3 passes:
 *
 *   # microgrommings   passes   %    accum. %
 *          61             1    61      61
 *          27             2    27      88
 *           9             3     9      97
 *           3             4     3     100
 *         ---
 *         100
 *
 *   So, it's not so slow. Anyway, a better algorithm could be
 *   implemented using 2 additional arrays, with MICROGROOM_STOP_AFTER
 *   positions each, to store the indexes of the candidate buckets
 *   found with distance equal to 1 or 2 while we scan for distance 0.
 *   Those with distance 0 are zeroed immediatelly. If none with
 *   distance 0 is found, we'll zero the indexes stored in the first
 *   array. Again, if none is found in the first array, we'll try the
 *   second one. Finally, if none is found in both arrays, the loop
 *   will continue until one bucket is zeroed.
 *
 *   But now comes the question: do the numbers above justify the
 *   additional code/work? I'll try to find out the answer
 *   implementing it :), but this has low priority for now.
 *
 */


  /* try features in their right place first */
  max_distance = 1;
  /* fprintf(stderr, "packstart: %ld,  packlen: %ld, max_zeroed_buckets: %ld\n",
     packstart, packlen, microgroom_stop_after); */

  /* while no bucket is zeroed...  */
  while (zeroed_countdown == microgroom_stop_after)
    {
      /*
         fprintf(stderr, "Start: %lu, stop_after: %u, max_distance: %lu,
         min_value: %lu\n", packstart,
         microgroom_stop_after, max_distance, min_value);
       */
      i_aux = packstart;
      while (BUCKET_IN_CHAIN (class, i_aux) && zeroed_countdown > 0)
	{
	  /* check if it's a candidate */
	  if ((BUCKET_VALUE (class, i_aux) == min_value) &&
	      (!BUCKET_IS_LOCKED (class, i_aux) || (groom_locked != 0)))
	    {
	      /* if it is, check the distance */
	      right_position = HASH_INDEX (class, BUCKET_HASH (class, i_aux));
	      if (right_position <= i_aux)
		distance = i_aux - right_position;
	      else
		distance = NUM_BUCKETS (class) + i_aux - right_position;
	      if (distance < max_distance)
		{
		  MARK_IT_FREE (class, i_aux);
		  zeroed_countdown--;
		}
	    }
	  i_aux++;
	  if (i_aux >= NUM_BUCKETS (class))
	    i_aux = 0;
	}

      /*  if none was zeroed, increase the allowed distance between the */
      /*  candidade's position and its right place. */
      if (zeroed_countdown == microgroom_stop_after)
	max_distance++;
    }

  /*
     fprintf (stderr,
     "Leaving microgroom: %ld buckets with value %ld zeroed at distance %ld\n",
     microgroom_stop_after - zeroed_countdown, h[i].value, max_distance - 1);
   */

  /* now we pack the chains */
  osbf_packchain (class, packstart, packlen);

  /* return the number of zeroed buckets */
  return (microgroom_stop_after - zeroed_countdown);
}

/*****************************************************************/

/* get next bucket index */
uint32_t
osbf_next_bindex (CLASS_STRUCT * class, uint32_t bindex)
{
  bindex++;
  if (bindex >= NUM_BUCKETS (class))
    bindex = 0;
  return bindex;
}

/*****************************************************************/

/* get the index of the last bucket in a chain */
uint32_t
osbf_last_in_chain (CLASS_STRUCT * class, uint32_t bindex)
{
  uint32_t wraparound;

  /* if the bucket is not in a chain, return an index */
  /* out of the buckets space, equal to the number of */
  /* buckets in the file to indicate an empty chain */
  if (!BUCKET_IN_CHAIN (class, bindex))
    return NUM_BUCKETS (class);

  wraparound = bindex;
  while (BUCKET_IN_CHAIN (class, bindex))
    {
      bindex++;
      if (bindex >= NUM_BUCKETS (class))
	bindex = 0;

      /* if .cfc file is full return an index out of */
      /* the buckets space, equal to number of buckets */
      /* in the file, plus one */
      if (bindex == wraparound)
	return NUM_BUCKETS (class) + 1;
    }

  if (bindex == 0)
    bindex = NUM_BUCKETS (class) - 1;
  else
    bindex--;

  return bindex;
}

/*****************************************************************/

/* get previous bucket index */
uint32_t
osbf_prev_bindex (CLASS_STRUCT * class, uint32_t bindex)
{
  if (bindex == 0)
    bindex = NUM_BUCKETS (class) - 1;
  else
    bindex--;
  return bindex;
}

/*****************************************************************/

/* get the index of the first bucket in a chain */
uint32_t
osbf_first_in_chain (CLASS_STRUCT * class, uint32_t bindex)
{
  uint32_t wraparound;

  /* if the bucket is not in a chain, return an index */
  /* out of the buckets space, equal to the number of */
  /* buckets in the file to indicate an empty chain */
  if (!BUCKET_IN_CHAIN (class, bindex))
    return NUM_BUCKETS (class);

  wraparound = bindex;
  while (BUCKET_IN_CHAIN (class, bindex))
    {
      if (bindex == 0)
	bindex = NUM_BUCKETS (class) - 1;
      else
	bindex--;

      /* if .cfc file is full return an index out of */
      /* the buckets space, equal to number of buckets */
      /* in the file, plus one */
      if (bindex == wraparound)
	return NUM_BUCKETS (class) + 1;
    }

  bindex++;
  if (bindex >= NUM_BUCKETS (class))
    bindex = 0;

  return bindex;
}

/*****************************************************************/

uint32_t
osbf_find_bucket (CLASS_STRUCT * class, uint32_t hash, uint32_t key)
{
  uint32_t bindex, start;

  bindex = start = HASH_INDEX (class, hash);
  while (BUCKET_IN_CHAIN (class, bindex) &&
	 !BUCKET_HASH_COMPARE (class, bindex, hash, key))
    {
      bindex = NEXT_BUCKET (class, bindex);

      /* if .cfc file is completely full return an index */
      /* out of the buckets space, equal to number of buckets */
      /* in the file, plus one */
      if (bindex == start)
	return NUM_BUCKETS (class) + 1;
    }

  /* return the index of the found bucket or, if not found,
   * the index of a free bucket where it could be put
   */
  return bindex;
}

/*****************************************************************/

void
osbf_update_bucket (CLASS_STRUCT * class, uint32_t bindex, int delta)
{

  /*
   * fprintf (stderr, "Bucket updated at %lu, hash: %lu, key: %lu, value: %d\n",
   *       bindex, hashes[bindex].hash, hashes[bindex].key, delta);
   */

  if (delta > 0 &&
      BUCKET_VALUE (class, bindex) + delta >= OSBF_MAX_BUCKET_VALUE)
    {
      SETL_BUCKET_VALUE (class, bindex, OSBF_MAX_BUCKET_VALUE);
    }
  else if (delta < 0 && BUCKET_VALUE (class, bindex) <= (uint32_t) (-delta))
    {
      if (BUCKET_VALUE (class, bindex) != 0)
	{
	  uint32_t i, packlen;

	  MARK_IT_FREE (class, bindex);

	  /* pack chain */
	  i = osbf_last_in_chain (class, bindex);
	  if (i >= bindex)
	    packlen = i - bindex + 1;
	  else
	    packlen = NUM_BUCKETS (class) - (bindex - i) + 1;
/*
	    fprintf (stderr, "packing: %" PRIu32 ", %" PRIu32 "\n", i,
		     bindex);
*/
	  osbf_packchain (class, bindex, packlen);
	}
    }
  else
    {
      SETL_BUCKET_VALUE (class, bindex, BUCKET_VALUE (class, bindex) + delta);
    }
}


/*****************************************************************/

void
osbf_insert_bucket (CLASS_STRUCT * class,
		    uint32_t bindex, uint32_t hash, uint32_t key, int value)
{
  uint32_t right_index, distance;
  int microgroom = 1;

  /* "right" bucket index */
  right_index = HASH_INDEX (class, hash);
  /* distance from right position to free position */
  distance = (bindex >= right_index) ? bindex - right_index :
    NUM_BUCKETS (class) - (right_index - bindex);

  /* if not specified, max chain len is automatically specified */
  if (microgroom_chain_length == 0)
    {
      /* from experimental values */
      microgroom_chain_length = 14.85 + 1.5E-4 * NUM_BUCKETS (class);
      /* not less than 29 */
      if (microgroom_chain_length < 29)
	microgroom_chain_length = 29;
    }

  if (microgroom && (value > 0))
    while (distance > microgroom_chain_length)
      {
	/*
	 * fprintf (stderr, "hindex: %lu, bindex: %lu, distance: %lu\n",
	 *          hindex, bindex, distance);
	 */
	osbf_microgroom (class, PREV_BUCKET (class, bindex));
	/* get new free bucket index */
	bindex = osbf_find_bucket (class, hash, key);
	distance = (bindex >= right_index) ? bindex - right_index :
	  NUM_BUCKETS (class) - (right_index - bindex);
      }

  /*
   *   fprintf (stderr,
   *   "new bucket at %lu, hash: %lu, key: %lu, distance: %lu\n",
   *         bindex, hash, key, distance);
   */

  SETL_BUCKET_VALUE (class, bindex, value);
  BUCKET_HASH (class, bindex) = hash;
  BUCKET_KEY (class, bindex) = key;
}

/*****************************************************************/

uint32_t
strnhash (unsigned char *str, uint32_t len)
{
  uint32_t i;
#ifdef CRM114_COMPATIBILITY
  int32_t hval;			/* signed int for CRM114 compatibility */
#else
  uint32_t hval;
#endif
  uint32_t tmp;

  /* initialize hval */
  hval = len;

  /*  for each character in the incoming text: */
  for (i = 0; i < len; i++)
    {
      /*
       *  xor in the current byte against each byte of hval
       *  (which alone gaurantees that every bit of input will have
       *  an effect on the output)
       */

      tmp = str[i];
      tmp = tmp | (tmp << 8) | (tmp << 16) | (tmp << 24);
      hval ^= tmp;

      /*    add some bits out of the middle as low order bits. */
      hval = hval + ((hval >> 12) & 0x0000ffff);

      /*     swap most and min significative bytes */
      tmp = (hval << 24) | ((hval >> 24) & 0xff);
      hval &= 0x00ffff00;	/* zero most and least significative bytes of hval */
      hval |= tmp;		/* OR with swapped bytes */

      /*    rotate hval 3 bits to the left (thereby making the */
      /*    3rd msb of the above mess the hsb of the output hash) */
      hval = (hval << 3) + (hval >> 29);
    }
  return (uint32_t) hval;
}

/*****************************************************************/

static OSBF_HEADER_BUCKET_UNION hu;
int
osbf_create_cfcfile (const char *cfcfile, uint32_t num_buckets,
		     uint32_t major, uint32_t minor, char *errmsg)
{
  FILE *f;
  uint32_t i_aux;
  OSBF_BUCKET_STRUCT bucket = { 0, 0, 0 };

  if (cfcfile == NULL || *cfcfile == '\0')
    {
      if (cfcfile != NULL)
	snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
		  "Invalid file name: '%s'", cfcfile);
      else
	strncpy (errmsg, "Invalid (NULL) pointer to cfc file name",
		 OSBF_ERROR_MESSAGE_LEN);
      return -1;
    }

  f = fopen (cfcfile, "r");
  if (f)
    {
      snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
		"File already exists: '%s'", cfcfile);
      fclose(f);
      return -1;
    }

  f = fopen (cfcfile, "wb");
  if (!f)
    {
      snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
		"Couldn't create the file: '%s'", cfcfile);
      return -1;
    }

  /* Set the header. */
  hu.header.version = major;
  hu.header.db_flags = minor;
  hu.header.buckets_start = OSBF_CFC_HEADER_SIZE;
  hu.header.num_buckets = num_buckets;
  hu.header.learnings = 0;

  /* Write header */
  if (fwrite (&hu, sizeof (hu), 1, f) != 1)
    {
      snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
		"Couldn't initialize the file header: '%s'", cfcfile);
      return -1;
    }

  /*  Initialize CFC hashes - zero all buckets */
  for (i_aux = 0; i_aux < num_buckets; i_aux++)
    {
      /* Write buckets */
      if (fwrite (&bucket, sizeof (bucket), 1, f) != 1)
	{
	  snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
		    "Couldn't write to: '%s'", cfcfile);
	  return -1;
	}
    }
  fclose (f);
  return 0;
}

/*****************************************************************/

/* Check if a file exists. Return its length if yes and < 0 if no */
off_t
check_file (const char *file)
{
  int fd;
  off_t fsize;

  fd = open (file, O_RDONLY);
  if (fd < 0)
    return -1;
  fsize = lseek (fd, 0L, SEEK_END);
  if (fsize < 0)
    return -2;
  close (fd);

  return fsize;
}

/*****************************************************************/

int
osbf_open_class (const char *classname, int flags, CLASS_STRUCT * class,
		 char *errmsg)
{
  int prot;
  off_t fsize;

  /* clear class structure */
  class->fd = -1;
  class->flags = O_RDONLY;
  class->classname = NULL;
  class->header = NULL;
  class->buckets = NULL;
  class->bflags = NULL;

  fsize = check_file (classname);
  if (fsize < 0)
    {
      snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN, "Couldn't open %s.",
		classname);
      return (-1);
    }

  /* open the class to be trained and mmap it into memory */
  class->fd = open (classname, flags);

  if (class->fd < 0)
    {
      snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
		"Couldn't open the file %s.", classname);
      return -2;
    }

  if (flags == O_RDWR)
    {
      class->flags = O_RDWR;
      prot = PROT_READ + PROT_WRITE;

#if (1)
      if (osbf_lock_file (class->fd, 0, 0) != 0)
	{
	  fprintf (stderr, "Couldn't lock the file %s.", classname);
	  close (class->fd);
	  snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
		    "Couldn't lock the file %s.", classname);
	  return -3;
	}
#endif

    }
  else
    {
      class->flags = O_RDONLY;
      prot = PROT_READ;
    }

  class->header = (OSBF_HEADER_STRUCT *) mmap (NULL, fsize, prot,
					       MAP_SHARED, class->fd, 0);
  if (class->header == MAP_FAILED)
    {
      close (class->fd);
      snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN, "Couldn't mmap %s.",
		classname);
      return (-4);
    }

  /* check file version */
  if (class->header->version != OSBF_VERSION || class->header->db_flags != 0)
    {
      snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
		"%s is not an OSBF_Bayes-spectrum file.", classname);
      return (-5);
    }

  class->bflags = calloc (class->header->num_buckets, sizeof (unsigned char));
  if (!class->bflags)
    {
      close (class->fd);
      munmap ((void *) class->header, (class->header->buckets_start +
				       class->header->num_buckets) *
	      sizeof (OSBF_BUCKET_STRUCT));
      snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
		"Couldn't allocate memory for seen features array.");
      return (-6);
    }

  class->classname = classname;
  class->buckets = (OSBF_BUCKET_STRUCT *) class->header +
    class->header->buckets_start;

  return 0;
}

/*****************************************************************/

int
osbf_close_class (CLASS_STRUCT * class, char *errmsg)
{
  int err = 0;

  if (class->header)
    {
      munmap ((void *) class->header, (class->header->buckets_start +
				       class->header->num_buckets) *
	      sizeof (OSBF_BUCKET_STRUCT));
      class->header = NULL;
      class->buckets = NULL;
    }

  if (class->bflags)
    {
      free (class->bflags);
      class->bflags = NULL;
    }

  if (class->fd >= 0)
    {
      if (class->flags == O_RDWR)
	{
	  /* "touch" the file */
	  OSBF_HEADER_STRUCT foo;
	  read (class->fd, &foo, sizeof (foo));
	  lseek (class->fd, 0, SEEK_SET);
	  write (class->fd, &foo, sizeof (foo));

#if (1)
	  if (osbf_unlock_file (class->fd, 0, 0) != 0)
	    {
	      snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
			"Couldn't unlock file: %s", class->classname);
	      err = -1;
	    }
#endif

	}
      close (class->fd);
      class->fd = -1;
    }

  return err;
}

/*****************************************************************/

int
osbf_lock_file (int fd, uint32_t start, uint32_t len)
{
  struct flock fl;
  int max_lock_attempts = 20;
  int errsv = 0;

  fl.l_type = F_WRLCK;		/* write lock */
  fl.l_whence = SEEK_SET;
  fl.l_start = start;
  fl.l_len = len;

  while (max_lock_attempts > 0)
    {
      errsv = 0;
      if (fcntl (fd, F_SETLK, &fl) < 0)
	{
	  errsv = errno;
	  if (errsv == EAGAIN || errsv == EACCES)
	    {
	      max_lock_attempts--;
	      sleep (1);
	    }
	  else
	    break;
	}
      else
	break;
    }
  return errsv;
}

/*****************************************************************/

int
osbf_unlock_file (int fd, uint32_t start, uint32_t len)
{
  struct flock fl;

  fl.l_type = F_UNLCK;
  fl.l_whence = SEEK_SET;
  fl.l_start = start;
  fl.l_len = len;
  if (fcntl (fd, F_SETLK, &fl) == -1)
    return -1;
  else
    return 0;
}


/*****************************************************************/

int
osbf_dump (const char *cfcfile, const char *csvfile, char *errmsg)
{
  FILE *fp_cfc, *fp_csv;
  OSBF_BUCKET_STRUCT buckets[BUCKET_BUFFER_SIZE];
  OSBF_HEADER_STRUCT header;
  int32_t i, size_in_buckets;
  int error = 0;

  fp_cfc = fopen (cfcfile, "rb");
  if (fp_cfc != NULL)
    {
      int32_t num_buckets;

      if (1 == fread (&header, sizeof (header), 1, fp_cfc))
	{
	  size_in_buckets = header.num_buckets + header.buckets_start;
	  fp_csv = fopen (csvfile, "w");
	  if (fp_csv != NULL)
	    {
	      fseek (fp_cfc, 0, SEEK_SET);
	      while (size_in_buckets > 0)
		{
		  num_buckets = fread (buckets, sizeof (OSBF_BUCKET_STRUCT),
				       BUCKET_BUFFER_SIZE, fp_cfc);
		  if (num_buckets > 0)
		    {
		      for (i = 0; i < num_buckets; i++)
			{
			  fprintf (fp_csv,
				   "%" PRIu32 ";%" PRIu32 ";%" PRIu32 "\n",
				   buckets[i].hash, buckets[i].key,
				   buckets[i].value);
			}
		    }
		  size_in_buckets -= num_buckets;
		}
	      fclose (fp_cfc);
	      fclose (fp_csv);
	      if (size_in_buckets != 0)
		{
		  error = 1;
		  strncpy (errmsg, "Not a valid cfc file",
			   OSBF_ERROR_MESSAGE_LEN);
		}
	    }
	  else
	    {
	      error = 1;
	      strncpy (errmsg, "Can't create csv file",
		       OSBF_ERROR_MESSAGE_LEN);
	    }
	}
      else
	{
	  error = 1;
	  strncpy (errmsg, "Error reading cfc file", OSBF_ERROR_MESSAGE_LEN);
	}
    }
  else
    {
      error = 1;
      strncpy (errmsg, "Can't open cfc file", OSBF_ERROR_MESSAGE_LEN);
    }

  return error;
}

/*****************************************************************/

int
osbf_restore (const char *cfcfile, const char *csvfile, char *errmsg)
{
  FILE *fp_cfc, *fp_csv;
  OSBF_BUCKET_STRUCT buckets[BUCKET_BUFFER_SIZE];
  OSBF_HEADER_STRUCT *header = (OSBF_HEADER_STRUCT *) buckets;
  int32_t size_in_buckets;
  int error = 0;

/*
  if (check_file(cfcfile) >= 0)
    {
      strncpy (errmsg, "The .cfc file already exists!", OSBF_ERROR_MESSAGE_LEN);
      return 1;
    }
*/

  fp_csv = fopen (csvfile, "r");
  if (fp_csv != NULL)
    {
      /* read header */
      if (5 ==
	  fscanf (fp_csv,
		  "%" SCNu32 ";%" SCNu32 ";%" SCNu32 "\n%" SCNu32 ";%" SCNu32
		  "\n", &header->version, &header->db_flags,
		  &header->buckets_start, &header->num_buckets,
		  &header->learnings))
	{
	  size_in_buckets = header->buckets_start + header->num_buckets;
	  fp_cfc = fopen (cfcfile, "wb");
	  fseek (fp_csv, 0, SEEK_SET);
	  if (fp_cfc != NULL)
	    {

	      while (error == 0
		     && 3 == fscanf (fp_csv,
				     "%" SCNu32 ";%" SCNu32 ";%" SCNu32
				     "\n", (uint32_t *) & buckets[0].hash,
				     (uint32_t *) & buckets[0].key,
				     (uint32_t *) & buckets[0].value))
		{
		  if (1 ==
		      fwrite (buckets, sizeof (OSBF_BUCKET_STRUCT), 1,
			      fp_cfc))
		    {
		      size_in_buckets--;
		    }
		  else
		    {
		      error = 1;
		      strncpy (errmsg, "Error writing to cfc file",
			       OSBF_ERROR_MESSAGE_LEN);
		    }
		}
	      if (!(feof (fp_csv) && size_in_buckets == 0))
		{
		  remove (cfcfile);
		  error = 1;
		  strncpy (errmsg,
			   "Error reading csv or not a valid csv file",
			   OSBF_ERROR_MESSAGE_LEN);
		}
	      fclose (fp_cfc);
	      fclose (fp_csv);
	    }
	  else
	    {
	      fclose (fp_csv);
	      error = 1;
	      strncpy (errmsg, "Can't create cfc file",
		       OSBF_ERROR_MESSAGE_LEN);
	    }
	}
      else
	{
	  fclose (fp_csv);
	  remove (cfcfile);
	  error = 1;
	  strncpy (errmsg, "csv file doesn't have a valid header",
		   OSBF_ERROR_MESSAGE_LEN);
	}
    }
  else
    {
      error = 1;
      strncpy (errmsg, "Can't open csv file", OSBF_ERROR_MESSAGE_LEN);
    }

  return error;
}

/*****************************************************************/

int
osbf_import (const char *cfcfile_to, const char *cfcfile_from, char *errmsg)
{
  uint32_t bindex;
  CLASS_STRUCT class_to, class_from;
  int error = 0;

  /* open the class to be trained and mmap it into memory */
  error = osbf_open_class (cfcfile_to, O_RDWR, &class_to, errmsg);
  if (error != 0)
    return 1;
  error = osbf_open_class (cfcfile_from, O_RDONLY, &class_from, errmsg);
  if (error != 0)
    return 1;

  {
    uint32_t i = 0;

    class_to.header->learnings += class_from.header->learnings;
    class_to.header->extra_learnings += class_from.header->extra_learnings;
    class_to.header->classifications += class_from.header->classifications;
    class_to.header->mistakes += class_from.header->mistakes;

    for (i = 0; i < class_from.header->num_buckets; i++)
      {
	if (class_from.buckets[i].value == 0)
	  continue;

	bindex = osbf_find_bucket (&class_to,
				   class_from.buckets[i].hash,
				   class_from.buckets[i].key);
	if (bindex < class_to.header->num_buckets)
	  {
	    if (BUCKET_IN_CHAIN (&class_to, bindex))
	      {
		osbf_update_bucket (&class_to, bindex,
				    class_from.buckets[i].value);
	      }
	    else
	      {
		osbf_insert_bucket (&class_to, bindex,
				    class_from.buckets[i].hash,
				    class_from.buckets[i].key,
				    class_from.buckets[i].value);
	      }
	  }
	else
	  {
	    error = 1;
	    strncpy (errmsg, ".cfc file is full!", OSBF_ERROR_MESSAGE_LEN);
	    break;
	  }

      }

    osbf_close_class (&class_to, errmsg);
    osbf_close_class (&class_from, errmsg);
  }

  return error;
}

/*****************************************************************/

int
osbf_stats (const char *cfcfile, STATS_STRUCT * stats,
	    char *errmsg, int full)
{

  FILE *fp_cfc;
  OSBF_BUCKET_STRUCT *buckets = NULL;
  OSBF_HEADER_STRUCT header;
  uint32_t i = 0, j = 0;
  int error = 0;

  uint32_t used_buckets = 0, unreachable = 0;
  uint32_t max_chain = 0, num_chains = 0;
  uint32_t max_value = 0, first_chain_len = 0;
  uint32_t max_displacement = 0, chain_len_sum = 0;

  fp_cfc = fopen (cfcfile, "rb");
  if (fp_cfc != NULL)
    {

      if (1 == fread (&header, sizeof (header), 1, fp_cfc))
	{
	  uint32_t chain_len = 0, value;
	  uint32_t buckets_in_buffer = 0, buffer_readings = 0;
	  uint32_t bucket_buffer_size = 0;

	  /* Check version */
	  if (header.version != OSBF_VERSION || header.db_flags != 0)
	    {
	      strncpy (errmsg, "Error: not a valid OSBF-Bayes file",
		       OSBF_ERROR_MESSAGE_LEN);
	      error = 1;
	    }
	  else
	    {
	      bucket_buffer_size =
		header.num_buckets * sizeof (OSBF_BUCKET_STRUCT);
	      buckets = malloc (bucket_buffer_size);
	      if (buckets == NULL)
		{
		  strncpy (errmsg, "Error allocating memory",
			   OSBF_ERROR_MESSAGE_LEN);
		  error = 1;
		}
	      else if (error == 0)
		{
		  error = fseek (fp_cfc,
				 header.buckets_start *
				 sizeof (OSBF_BUCKET_STRUCT), SEEK_SET);
		  if (error == 0)
		    {
		      buckets_in_buffer =
			fread (buckets, sizeof (OSBF_BUCKET_STRUCT),
			       header.num_buckets, fp_cfc);
		      if (buckets_in_buffer != header.num_buckets)
			{
			  error = 1;
			  snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
				    "Wrong number of buckets read from '%s'",
				    cfcfile);
			}
		    }
		  else
		    {
		      snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
				"'%s': fseek error", cfcfile);
		    }

		  buffer_readings = chain_len = j = 0;
		}
	    }

	  if (full == 1) {
	  while (error == 0 && buckets_in_buffer > 0)
	    {
	      j++;		/* number of reads */
	      if (buckets_in_buffer > 0)
		{
		  for (i = 0; i < buckets_in_buffer; i++)
		    {
		      if ((value = buckets[i].value) != 0)
			{
			  uint32_t distance, right_position;
			  uint32_t real_position, rp;

			  used_buckets++;
			  chain_len++;
			  if (value > max_value)
			    max_value = value;

			  /* calculate max displacement */
			  right_position = buckets[i].hash %
			    header.num_buckets;
			  real_position = i;
			  if (right_position <= real_position)
			    distance = real_position - right_position;
			  else
			    distance = header.num_buckets + real_position -
			      right_position;
			  if (distance > max_displacement)
			    max_displacement = distance;

			  /* check if the bucket is unreachable */
			  for (rp = right_position; rp != real_position; rp++)
			    {
			      if (rp >= header.num_buckets)
				{
				  rp = 0;
				  if (rp == real_position)
				    break;
				}
			      if (buckets[rp].value == 0)
				break;
			    }
			  if (rp != real_position)
			    {
			      unreachable++;
			    }
			}
		      else
			{
			  if (chain_len > 0)
			    {
			      if (chain_len > max_chain)
				max_chain = chain_len;
			      chain_len_sum += chain_len;
			      num_chains++;
			      chain_len = 0;
			      /* check if the first chain starts */
			      /* at the the first bucket */
			      if (j == 1 && num_chains == 1 &&
				  buckets[0].value != 0)
				first_chain_len = chain_len;
			    }
			}
		    }
		  buckets_in_buffer = fread (buckets,
					     sizeof (OSBF_BUCKET_STRUCT),
					     bucket_buffer_size, fp_cfc);
		  if (feof (fp_cfc))
		    buckets_in_buffer = 0;
		  if (buckets_in_buffer > 0)
		    buffer_readings++;
		}
	    }
	  }

	  if (error != 0)
	    {
	      if (ferror (fp_cfc))
		{
		  error = 1;
		  strncpy (errmsg, "Error reading cfc file",
			   OSBF_ERROR_MESSAGE_LEN);
		}
	    }
	  else
	    {
	      /* check if last and first chains are the same */
	      if (chain_len > 0)
		{
		  if (first_chain_len == 0)
		    num_chains++;
		  else
		    chain_len += first_chain_len;
		  chain_len_sum += chain_len;
		  if (chain_len > max_chain)
		    max_chain = chain_len;
		}
	    }
	  fclose (fp_cfc);
	}
      else
	{
	  error = 1;
	  fclose (fp_cfc);
	  strncpy (errmsg, "Error reading cfc file", OSBF_ERROR_MESSAGE_LEN);
	}
    }
  else
    {
      error = 1;
      strncpy (errmsg, "Can't open cfc file", OSBF_ERROR_MESSAGE_LEN);
    }

  if (error == 0)
    {
      stats->version = header.version;
      stats->total_buckets = header.num_buckets;
      stats->bucket_size = sizeof (OSBF_BUCKET_STRUCT);
      stats->used_buckets = used_buckets;
      stats->header_size = header.buckets_start * sizeof (OSBF_BUCKET_STRUCT);
      stats->learnings = header.learnings;
      stats->extra_learnings = header.extra_learnings;
      stats->mistakes = header.mistakes;
      stats->classifications = header.classifications;
      stats->num_chains = num_chains;
      stats->max_chain = max_chain;
      if (num_chains > 0)
	stats->avg_chain = (double) chain_len_sum / num_chains;
      else
	stats->avg_chain = 0;
      stats->max_displacement = max_displacement;
      stats->unreachable = unreachable;
    }

  return error;
}

/*****************************************************************/
