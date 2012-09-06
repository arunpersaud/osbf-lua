/*
 * osbf_bayes.c
 * 
 * This software is licensed to the public under the Free Software
 * Foundation's GNU GPL, version 2.  You may obtain a copy of the
 * GPL by visiting the Free Software Foundations web site at
 * www.fsf.org, and a copy is included in this distribution.  
 *
 * Copyright 2005, 2006, 2007 Fidelis Assis, all rights reserved.
 * Copyright 2005, 2006, 2007 Williams Yerazunis, all rights reserved.
 *
 * Read the HISTORY_AND_AGREEMENT for details.
 *
 */

#include <stdio.h>
#include <ctype.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <math.h>
#include <sys/mman.h>
#include <inttypes.h>
#include <errno.h>

#define DEBUG 0

/*  OSBF structures */
#include "osbflib.h"

struct token_search
{
  unsigned char *ptok;
  unsigned char *ptok_max;
  uint32_t toklen;
  uint32_t hash;
  const char *delims;
};

#define TMPBUFFSIZE 512
char tempbuf[TMPBUFFSIZE + 2];

extern uint32_t microgroom_chain_length;
uint32_t max_token_size = OSBF_MAX_TOKEN_SIZE;
uint32_t max_long_tokens = OSBF_MAX_LONG_TOKENS;
uint32_t limit_token_size = 0;

/*
 *   the hash coefficient tables should be full of relatively prime numbers,
 *   and preferably superincreasing, though both of those are not strict
 *   requirements. The two tables must not have a common prime.
 */
static uint32_t hctable1[] = { 1, 3, 5, 11, 23, 47, 97, 197, 397, 797 };
static uint32_t hctable2[] =
  { 7, 13, 29, 51, 101, 203, 407, 817, 1637, 3277 };

/* constants used in the CF formula */
double K1 = 0.25, K2 = 12, K3 = 8;

/*****************************************************************/
/* experimental code */
#if (0)
static double
lnfact (uint32_t n)
{
  static double lnfact_table[1001];

  if (n <= 1)
    return 0.0;
  if (n <= 1000)
    return lnfact_table[n] ?
      lnfact_table[n] : (lnfact_table[n] = lgamma (n + 1.0));
  else
    return lgamma (n + 1.0);
}

static double
conf_factor (uint32_t n, uint32_t k, double interval)
{
  uint32_t i, j, start, end;
  double b, sum;

  j = floor (0.5 + interval * n);

  if (j > k)
    start = 0;
  else
    start = k - j;

  if (j + k <= n)
    end = j + k;
  else
    end = n;

  sum = 0;
  for (i = start; i <= end; i++)
    {
      b = exp (lnfact (n) - lnfact (i) - lnfact (n - i) - n * log (2));
      if (sum + b < 1)
	sum += b;
    }

  return 1 - sum;
}
#endif

/*****************************************************************/

static unsigned char *
get_next_token (unsigned char *p_text, unsigned char *max_p,
		const char *delims, uint32_t * p_toklen)
{
  unsigned char *p_ini = p_text;

  if (delims == NULL)
    return NULL;

  /* find nongraph delimited token */
  while ((p_text < max_p) &&
	 (!isgraph ((int) *p_text) || strchr (delims, (int) *p_text)))
    p_text++;
  p_ini = p_text;

  if (limit_token_size == 0)
    {
      /* don't limit the tokens */
      while ((p_text < max_p) && isgraph ((int) *p_text) &&
	     !strchr (delims, (int) *p_text))
	p_text++;
    }
  else
    {
      /* limit the tokens to max_token_size */
      while ((p_text < max_p) && (p_text < (p_ini + max_token_size)) &&
	     isgraph ((int) *p_text) && !strchr (delims, (int) *p_text))
	p_text++;
    }

  *p_toklen = p_text - p_ini;

#if (0)
  {
    uint32_t i = 0;
    while (i < *p_toklen)
      fputc (p_ini[i++], stderr);
    fprintf (stderr, " - toklen: %" PRIu32
	     ", max_token_len: %" PRIu32
	     ", max_long_tokens: %" PRIu32 "\n",
	     *p_toklen, max_token_size, max_long_tokens);
  }
#endif

  return p_ini;
}

/*****************************************************************/

static uint32_t
get_next_hash (struct token_search *pts)
{
  uint32_t hash_acc = 0;
  uint32_t count_long_tokens = 0;
  int error = 0;

  pts->ptok += pts->toklen;
  pts->ptok = get_next_token (pts->ptok, pts->ptok_max,
			      pts->delims, &(pts->toklen));

#ifdef OSBF_MAX_TOKEN_SIZE
  /* long tokens, probably encoded lines */
  while (pts->toklen >= max_token_size && count_long_tokens < max_long_tokens)
    {
      count_long_tokens++;
      /* XOR new hash with previous one */
      hash_acc ^= strnhash (pts->ptok, pts->toklen);
      /* fprintf(stderr, " %0lX +\n ", hash_acc); */
      /* advance the pointer and get next token */
      pts->ptok += pts->toklen;
      pts->ptok = get_next_token (pts->ptok, pts->ptok_max,
				  pts->delims, &(pts->toklen));
    }


#endif

  if (pts->toklen > 0 || count_long_tokens > 0)
    {
      hash_acc ^= strnhash (pts->ptok, pts->toklen);
      pts->hash = hash_acc;
      /* fprintf(stderr, " %0lX %lu\n", hash_acc, pts->toklen); */
    }
  else
    {
      /* no more hashes */
      /* fprintf(stderr, "End of text %0lX %lu\n", hash_acc, pts->toklen); */
      error = 1;
    }

  return (error);
}

/******************************************************************/
/* Train the specified class with the text pointed to by "p_text" */
/******************************************************************/
int osbf_bayes_learn (const unsigned char *p_text,	/* pointer to text */
		      unsigned long text_len,	/* length of text */
		      const char *delims,	/* token delimiters */
		      const char *classnames[],	/* class file names */
		      uint32_t ctbt,	/* index of the class to be trained */
		      int sense,	/* 1 => learn;  -1 => unlearn */
		      uint32_t flags,	/* flags */
		      char *errmsg)
{
  int err;
  uint32_t window_idx;
  int32_t learn_error;
  int32_t h;
  off_t fsize;
  uint32_t hashpipe[OSB_BAYES_WINDOW_LEN + 1];
  int32_t num_hash_paddings;
  int microgroom;
  struct token_search ts;
  CLASS_STRUCT class[OSBF_MAX_CLASSES];

  /* fprintf(stderr, "Starting learning...\n"); */

  ts.ptok = (unsigned char *) p_text;
  ts.ptok_max = (unsigned char *) (p_text + text_len);
  ts.toklen = 0;
  ts.hash = 0;
  ts.delims = delims;

  microgroom = 1;
  if (flags & NO_MICROGROOM)
    microgroom = 0;

  fsize = check_file (classnames[ctbt]);
  if (fsize < 0)
    {
      snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN, "File not available: %s.",
		classnames[ctbt]);
      return (-1);
    }

  /* open the class to be trained and mmap it into memory */
  err = osbf_open_class (classnames[ctbt], O_RDWR, &class[ctbt], errmsg);
  if (err != 0)
    {
      snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN, "Couldn't open %s.",
		classnames[ctbt]);
      fprintf (stderr, "Couldn't open %s.", classnames[ctbt]);
      return err;
    }

  /*   init the hashpipe with 0xDEADBEEF  */
  for (h = 0; h < OSB_BAYES_WINDOW_LEN; h++)
    hashpipe[h] = 0xDEADBEEF;

  learn_error = 0;
  /* experimental code - set num_hash_paddings = 0 to disable */
  /* num_hash_paddings = OSB_BAYES_WINDOW_LEN - 1; */
  num_hash_paddings = OSB_BAYES_WINDOW_LEN - 1;
  while (learn_error == 0 && ts.ptok <= ts.ptok_max)
    {

      if (get_next_hash (&ts) != 0)
	{
	  /* after eof, insert fake tokens until the last real */
	  /* token comes out at the other end of the hashpipe */
	  if (num_hash_paddings-- > 0)
	    ts.hash = 0xDEADBEEF;
	  else
	    break;
	}

      /*  Shift the hash pipe down one and insert new hash */
      for (h = OSB_BAYES_WINDOW_LEN - 1; h > 0; h--)
	hashpipe[h] = hashpipe[h - 1];
      hashpipe[0] = ts.hash;

#if (DEBUG)
      {
	fprintf (stderr, "  Hashpipe contents: ");
	for (h = 0; h < OSB_BAYES_WINDOW_LEN; h++)
	  fprintf (stderr, " %" PRIu32, hashpipe[h]);
	fprintf (stderr, "\n");
      }
#endif

      {
	uint32_t hindex, bindex;
	uint32_t h1, h2;

	for (window_idx = 1; window_idx < OSB_BAYES_WINDOW_LEN; window_idx++)
	  {

	    h1 =
	      hashpipe[0] * hctable1[0] +
	      hashpipe[window_idx] * hctable1[window_idx];
	    h2 = hashpipe[0] * hctable2[0] +
#ifdef CRM114_COMPATIBILITY
	      hashpipe[window_idx] * hctable2[window_idx - 1];
#else
	      hashpipe[window_idx] * hctable2[window_idx];
#endif
	    hindex = h1 % class[ctbt].header->num_buckets;

#if (DEBUG)
	    fprintf (stderr,
		     "Polynomial %" PRIu32 " has h1:%" PRIu32 "  h2: %"
		     PRIu32 "\n", window_idx, h1, h2);
#endif

	    bindex = osbf_find_bucket (&class[ctbt], h1, h2);
	    if (bindex < class[ctbt].header->num_buckets)
	      {
		if (BUCKET_IN_CHAIN (&class[ctbt], bindex))
		  {
		    if (!BUCKET_IS_LOCKED (&class[ctbt], bindex))
		      osbf_update_bucket (&class[ctbt], bindex, sense);
		  }
		else if (sense > 0)
		  {
		    osbf_insert_bucket (&class[ctbt], bindex, h1, h2, sense);
		  }
	      }
	    else
	      {
		snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
			  ".cfc file is full!");
		learn_error = -1;
		break;
	      }
	  }
      }
    }				/*   end the while k==0 */


  if (learn_error == 0)
    {

      if (sense > 0)
	{
	  /* extra learnings are all those done with the  */
	  /* same document, after the first learning */
	  if (flags & EXTRA_LEARNING)
	    {
	      /* increment extra learnings counter */
	      class[ctbt].header->extra_learnings += 1;
	    }
	  else
	    {
	      /* increment normal learnings counter */

	      /* old code disabled because the databases are disjoint and
	         this correction should be applied to both simultaneously

	         class[ctbt].header->learnings += 1;
	         if (class[ctbt].header->learnings >= OSBF_MAX_BUCKET_VALUE)
	         {
	         uint32_t i;

	         class[ctbt].header->learnings >>= 1;
	         for (i = 0; i < NUM_BUCKETS (&class[ctbt]); i++)
	         BUCKET_VALUE (&class[ctbt], i) =
	         BUCKET_VALUE (&class[ctbt], i) >> 1;
	         }
	       */

	      if (class[ctbt].header->learnings < OSBF_MAX_BUCKET_VALUE)
		{
		  class[ctbt].header->learnings += 1;
		}

	      /* increment mistakes counter */
	      if (flags & MISTAKE)
		{
		  class[ctbt].header->mistakes += 1;
		}
	    }
	}
      else
	{
	  if (flags & EXTRA_LEARNING)
	    {
	      /* decrement extra learnings counter */
	      if (class[ctbt].header->extra_learnings > 0)
		class[ctbt].header->extra_learnings -= 1;
	    }
	  else
	    {
	      /* decrement learnings counter */
	      if (class[ctbt].header->learnings > 0)
		class[ctbt].header->learnings -= 1;
	      /* decrement mistakes counter */
	      if ((flags & MISTAKE) && class[ctbt].header->mistakes > 0)
		class[ctbt].header->mistakes -= 1;
	    }
	}
    }

  err = osbf_close_class (&class[ctbt], errmsg);

  if (learn_error != 0)
    return (learn_error);

  return (err);

}


/**********************************************************/
/* Find out the best class for the text pointed to by     */
/* "p_text", among those listed in the array "classnames" */
/**********************************************************/
int
osbf_bayes_classify (const unsigned char *p_text,	/* pointer to text */
		     unsigned long text_len,	/* length of text */
		     const char *delims,	/* token delimiters */
		     const char *classnames[],	/* hash file names */
		     uint32_t flags,	/* flags */
		     double min_pmax_pmin_ratio,
		     /* returned values */
		     double ptc[],	/* class probs */
		     uint32_t ptt[],	/* number trainings per class */
		     char *errmsg	/* err message, if any */
  )
{
  int err = 0;
  int32_t i, window_idx, class_idx;
  int32_t h;			/* we use h for our hashpipe counter, as needed. */

  off_t fsize;
  double htf;			/* hits this feature got. */
  double renorm = 0.0;
  uint32_t hashpipe[OSB_BAYES_WINDOW_LEN + 1];
  CLASS_STRUCT class[OSBF_MAX_CLASSES];

  int32_t num_classes;
  uint32_t total_learnings = 0;
  uint32_t totalfeatures;	/* total features */

  /* empirical weights: (5 - d) ^ (5 - d) */
  /* where d = number of skipped tokens in the sparse bigram */
  double feature_weight[] = { 0, 3125, 256, 27, 4, 1 };
  double exponent;
  double confidence_factor;
  int asymmetric = 0;		/* break local p loop early if asymmetric on */
  int voodoo = 1;		/* turn on the "voodoo" CF formula - default */

  struct token_search ts;

  ts.ptok = (unsigned char *) p_text;
  ts.ptok_max = (unsigned char *) (p_text + text_len);
  ts.toklen = 0;
  ts.hash = 0;
  ts.delims = delims;

  /* fprintf(stderr, "Starting classification...\n"); */

  if (flags & NO_EDDC)
    voodoo = 0;

  for (i = 0; (classnames[i] != NULL) && (i < OSBF_MAX_CLASSES); i++)
    {
      fsize = check_file (classnames[i]);
      if (fsize < 0)
	{
	  snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
		    "Couldn't open the file %s.", classnames[i]);
	  return (-1);
	}

      /*  mmap the hash file into memory */
      err = osbf_open_class (classnames[i], O_RDONLY, &class[i], errmsg);
      if (err != 0)
	{
	  snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
		    "Couldn't open the file %s.", classnames[i]);
	  return err;
	}

      ptt[i] = class[i].learnings = class[i].header->learnings;
      /* increment learnings to avoid division by 0 */
      if (class[i].learnings == 0)
	class[i].learnings++;

      /* update total learnings */
      total_learnings += class[i].learnings;
    }
  num_classes = i;
  exponent = pow (total_learnings * 3, 0.2);
  if (exponent < 5)
    {
      feature_weight[1] = pow (exponent, exponent);
      feature_weight[2] = pow (exponent * 4.0 / 5.0, exponent * 4.0 / 5.0);
      feature_weight[3] = pow (exponent * 3.0 / 5.0, exponent * 3.0 / 5.0);
      feature_weight[4] = pow (exponent * 2.0 / 5.0, exponent * 2.0 / 5.0);
    }

  if (num_classes == 0)
    {
      snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
		"At least one class must be given.");
      return (-1);
    }

  for (i = 0; i < num_classes; i++)
    {
      /*  initialize our arrays for N .cfc files */
      class[i].hits = 0.0;	/* absolute hit counts */
      class[i].totalhits = 0;	/* absolute hit counts */
      class[i].uniquefeatures = 0;	/* features counted per class */
      class[i].missedfeatures = 0;	/* missed features per class */
      ptc[i] = (double) class[i].learnings / total_learnings;	/* a priori probability */
    }

  /* do we have at least 1 valid .cfc files? */
  if (num_classes == 0)
    {
      snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
		"Couldn't open at least 2 .cfc files for classify().");
      return (-1);
    }

  /*   now all of the files are mmapped into memory, */
  /*   and we can do the polynomials and add up points. */
  i = 0;

  if (text_len == 0)
    {
      snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
		"Attempt to classify an empty text.");
      return (-1);
    }

  /* init the hashpipe with 0xDEADBEEF  */
  for (h = 0; h < OSB_BAYES_WINDOW_LEN; h++)
    {
      hashpipe[h] = 0xDEADBEEF;
    }

  totalfeatures = 0;

  while (ts.ptok <= ts.ptok_max)
    {
      if (get_next_hash (&ts) != 0)
	break;

      /* Shift the hash pipe down one and insert new hash */
      for (h = OSB_BAYES_WINDOW_LEN - 1; h > 0; h--)
	{
	  hashpipe[h] = hashpipe[h - 1];
	}

      hashpipe[0] = ts.hash;

      /* clean hash */
      ts.hash = 0;

      {
	uint32_t hindex;
	uint32_t h1, h2;
	/* remember indexes of classes with min and max local probabilities */
	int i_min_p, i_max_p;
	/* remember min and max local probabilities of a feature */
	double min_local_p, max_local_p;
	/* flag for already seen features */
	int already_seen;

	for (window_idx = 1; window_idx < OSB_BAYES_WINDOW_LEN; window_idx++)
	  {
	    h1 =
	      hashpipe[0] * hctable1[0] +
	      hashpipe[window_idx] * hctable1[window_idx];
	    h2 = hashpipe[0] * hctable2[0] +
#ifdef CRM114_COMPATIBILITY
	      hashpipe[window_idx] * hctable2[window_idx - 1];
#else
	      hashpipe[window_idx] * hctable2[window_idx];
#endif

	    hindex = h1;

#if (DEBUG)
	    fprintf (stderr,
		     "Polynomial %" PRIu32 " has h1:%i" PRIu32 "  h2: %"
		     PRIu32 "\n", window_idx, h1, h2);
#endif

	    htf = 0;
	    totalfeatures++;

	    min_local_p = 1.0;
	    max_local_p = 0;
	    i_min_p = i_max_p = 0;
	    already_seen = 0;
	    for (class_idx = 0; class_idx < num_classes; class_idx++)
	      {
		uint32_t lh, lh0;
		double p_feat = 0;

		lh = HASH_INDEX (&class[class_idx], hindex);
		lh0 = lh;
		class[class_idx].hits = 0;

		/* look for feature with hashes h1 and h2 */
		lh = osbf_find_bucket (&class[class_idx], h1, h2);

		/* the bucket is valid if its index is valid. if the     */
		/* index "lh" is >= the number of buckets, it means that */
		/* the .cfc file is full and the bucket wasn't found     */
		if (VALID_BUCKET (&class[class_idx], lh) &&
		    class[class_idx].bflags[lh] == 0)
		  {
		    /* only not previously seen features are considered */
		    if (BUCKET_IN_CHAIN (&class[class_idx], lh))
		      {
			/* count unique features used */
			class[class_idx].uniquefeatures += 1;

			class[class_idx].hits =
			  BUCKET_VALUE (&class[class_idx], lh);

			/* remember totalhits */
			class[class_idx].totalhits += class[class_idx].hits;

			/* and hits-this-feature */
			htf += class[class_idx].hits;
			p_feat = class[class_idx].hits /
			  class[class_idx].learnings;

			/* find class with minimum P(F) */
			if (p_feat <= min_local_p)
			  {
			    i_min_p = class_idx;
			    min_local_p = p_feat;
			  }

			/* find class with maximum P(F) */
			if (p_feat >= max_local_p)
			  {
			    i_max_p = class_idx;
			    max_local_p = p_feat;
			  }

			/* mark the feature as seen */
			class[class_idx].bflags[lh] = 1;
		      }
		    else
		      {
			/*
			 * a feature that wasn't found can't be marked as
			 * already seen in the doc because the index lh
			 * doesn't refer to it, but to the first empty bucket
			 * after the chain, which is common to all not-found
			 * features in the same chain. This is not a problem
			 * though, because if the feature is found in another
			 * class, it'll be marked as seen on that class,
			 * which is enough to mark it as seen. If it's not
			 * found in any class, it will have zero count on
			 * all classes and will be ignored as well. So, only
			 * found features are marked as seen.
			 */
			i_min_p = class_idx;
			min_local_p = p_feat = 0;
			/* for statistics only (for now...) */
			class[class_idx].missedfeatures += 1;
		      }
		  }
		else
		  {
		    if (VALID_BUCKET (&class[class_idx], lh))
		      {
			already_seen = 1;
			if (asymmetric != 0)
			  break;
		      }
		    else
		      {
			/* bucket not valid. treat like feature not found */
			i_min_p = class_idx;
			min_local_p = p_feat = 0;
			/* for statistics only (for now...) */
			class[class_idx].missedfeatures += 1;
		      }
		  }
	      }


	    /*=======================================================
	     * Update the probabilities using Bayes:
	     *
	     *                      P(F|S) P(S)
	     *     P(S|F) = -------------------------------
	     *               P(F|S) P(S) +  P(F|NS) P(NS)
	     *
	     * S = class spam; NS = class nonspam; F = feature
	     *
	     * Here we adopt a different method for estimating
	     * P(F|S). Instead of estimating P(F|S) as (hits[S][F] /
	     * (hits[S][F] + hits[NS][F])), like in the original
	     * code, we use (hits[S][F] / learnings[S]) which is the
	     * ratio between the number of messages of the class S
	     * where the feature F was observed during learnings and
	     * the total number of learnings of that class. Both
	     * values are kept in the respective .cfc file, the
	     * number of learnings in the header and the number of
	     * occurrences of the feature F as the value of its
	     * feature bucket.
	     *
	     * It's worth noting another important difference here:
	     * as we want to estimate the *number of messages* of a
	     * given class where a certain feature F occurs, we
	     * count only the first occurrence of each feature in a
	     * message (repetitions are ignored), both when learning
	     * and when classifying.
	     * 
	     * Advantages of this method, compared to the original:
	     *
	     * - First of all, and the most important: accuracy is
	     * really much better, at about the same speed! With
	     * this higher accuracy, it's also possible to increase
	     * the speed, at the cost of a low decrease in accuracy,
	     * using smaller .cfc files;
	     *
	     * - It is not affected by different sized classes
	     * because the numerator and the denominator belong to
	     * the same class;
	     *
	     * - It allows a simple and fast pruning method that
	     * seems to introduce little noise: just zero features
	     * with lower count in a overflowed chain, zeroing first
	     * those in their right places, to increase the chances
	     * of deleting older ones.
	     *
	     * Disadvantages:
	     *
	     * - It breaks compatibility with previous .css file
	     * format because of different header structure and
	     * meaning of the counts.
	     *
	     * Confidence factors
	     *
	     * The motivation for confidence factors is to reduce
	     * the noise introduced by features with small counts
	     * and/or low significance. This is an attempt to mimic
	     * what we do when inspecting a message to tell if it is
	     * spam or not. We intuitively consider only a few
	     * tokens, those which carry strong indications,
	     * according to what we've learned and remember, and
	     * discard the ones that may occur (approximately)
	     * equally in both classes.
	     *
	     * Once P(Feature|Class) is estimated as above, the
	     * calculated value is adjusted using the following
	     * formula:
	     *
	     *  CP(Feature|Class) = 0.5 + 
	     *             CF(Feature) * (P(Feature|Class) - 0.5)
	     *
	     * Where CF(Feature) is the confidence factor and
	     * CP(Feature|Class) is the adjusted estimate for the
	     * probability.
	     *
	     * CF(Feature) is calculated taking into account the
	     * weight, the max and the min frequency of the feature
	     * over the classes, using the empirical formula:
	     *
	     *     (((Hmax - Hmin)^2 + Hmax*Hmin - K1/SH) / SH^2) ^ K2
	     * CF(Feature) = ------------------------------------------
	     *                    1 +  K3 / (SH * Weight)
	     *
	     * Hmax  - Number of documents with the feature "F" on
	     * the class with max local probability;
	     * Hmin  - Number of documents with the feature "F" on
	     * the class with min local probability;
	     * SH - Sum of Hmax and Hmin
	     * K1, K2, K3 - Empirical constants
	     *
	     * OBS: - Hmax and Hmin are normalized to the max number
	     *  of learnings of the 2 classes involved.
	     *  - Besides modulating the estimated P(Feature|Class),
	     *  reducing the noise, 0 <= CF < 1 is also used to
	     *  restrict the probability range, avoiding the
	     *  certainty falsely implied by a 0 count for a given
	     *  class.
	     *
	     * -- Fidelis Assis
	     *=======================================================*/

	    /* ignore already seen features */
	    /* ignore less significant features (CF = 0) */
	    if ((already_seen != 0) || ((max_local_p - min_local_p) < 1E-6))
	      continue;
	    if ((min_local_p > 0)
		&& ((max_local_p / min_local_p) < min_pmax_pmin_ratio))
	      continue;

	    /* code under testing... */
	    /* calculate confidence_factor */
	    {
	      uint32_t hits_max_p, hits_min_p, sum_hits;
	      int32_t diff_hits;
	      double cfx = 1;
	      /* constants used in the CF formula */
	      /* K1 = 0.25; K2 = 10; K3 = 8;      */
	      /* const double K1 = 0.25, K2 = 10, K3 = 8; */

	      hits_min_p = class[i_min_p].hits;
	      hits_max_p = class[i_max_p].hits;

	      /* normalize hits to max learnings */
	      if (class[i_min_p].learnings < class[i_max_p].learnings)
		hits_min_p *=
		  (double) class[i_max_p].learnings /
		  (double) class[i_min_p].learnings;
	      else
		hits_max_p *=
		  (double) class[i_min_p].learnings /
		  (double) class[i_max_p].learnings;

	      sum_hits = hits_max_p + hits_min_p;
	      diff_hits = hits_max_p - hits_min_p;
	      if (diff_hits < 0)
		diff_hits = -diff_hits;

	      /* calculate confidence factor (CF) */
	      if (voodoo == 0)	/* || min_local_p > 0 ) */
		confidence_factor = 1 - OSBF_DBL_MIN;
	      else
#define EDDC_VARIANT 3
#if   (EDDC_VARIANT == 1)
		confidence_factor =
		  pow ((diff_hits * diff_hits +
			hits_max_p * hits_min_p -
			K1 / sum_hits) / (sum_hits * sum_hits),
		       K2) / (1.0 +
			      K3 / (sum_hits * feature_weight[window_idx]));
#elif (EDDC_VARIANT == 2)
		confidence_factor =
		  pow ((diff_hits * diff_hits - K1 / sum_hits) /
		       (sum_hits * sum_hits), K2) / (1.0 +
						     K3 / (sum_hits *
							   feature_weight
							   [window_idx]));
#elif (EDDC_VARIANT == 3)
		cfx =
		  0.8 + (class[i_min_p].header->learnings +
			 class[i_max_p].header->learnings) / 20.0;
	      if (cfx > 1)
		cfx = 1;
	      confidence_factor = cfx *
		pow ((diff_hits * diff_hits - K1 /
		      (class[i_max_p].hits + class[i_min_p].hits)) /
		     (sum_hits * sum_hits), 2) /
		(1.0 +
		 K3 / ((class[i_max_p].hits + class[i_min_p].hits) *
		       feature_weight[window_idx]));
#elif (EDDC_VARIANT == 4)
		confidence_factor =
		  conf_factor (sum_hits, diff_hits, 0.1) / (1.0 +
							    K3 / (sum_hits *
								  feature_weight
								  [window_idx]));
#endif

#if (DEBUG)
	      fprintf
		(stderr,
		 "CF: %.4f, max_hits = %3" PRIu32 ", min_hits = %3" PRIu32
		 ", " "weight: %5.1f\n", confidence_factor, hits_max_p,
		 hits_min_p, feature_weight[window_idx]);
#endif
	    }

	    /* calculate the numerators - P(F|C) * P(C) */
	    renorm = 0.0;
	    for (class_idx = 0; class_idx < num_classes; class_idx++)
	      {
		/*
		 * P(C) = learnings[k] / total_learnings
		 * P(F|C) = hits[k]/learnings[k], adjusted by the
		 * confidence factor.
		 */
		ptc[class_idx] = ptc[class_idx] * (0.5 + confidence_factor *
						   (class[class_idx].
						    hits /
						    class[class_idx].
						    learnings - 0.5));

		if (ptc[class_idx] < 10 * OSBF_DBL_MIN)
		  ptc[class_idx] = 10 * OSBF_DBL_MIN;
		renorm += ptc[class_idx];
#if (DEBUG)
		fprintf (stderr, "CF: %.4f, class[k].totalhits: %" PRIu32 ", "
			 "missedfeatures[k]: %" PRIu32
			 ", uniquefeatures[k]: %" PRIu32 ", "
			 "totalfeatures: %" PRIu32 ", weight: %5.1f\n",
			 confidence_factor, class[class_idx].totalhits,
			 class[class_idx].missedfeatures,
			 class[class_idx].uniquefeatures, totalfeatures,
			 feature_weight[window_idx]);
#endif

	      }

	    /* renormalize probabilities */
	    for (class_idx = 0; class_idx < num_classes; class_idx++)
	      ptc[class_idx] = ptc[class_idx] / renorm;

#if (DEBUG)
	    {
	      for (class_idx = 0; class_idx < num_classes; class_idx++)
		{
		  fprintf (stderr,
			   " poly: %" PRIu32 "  filenum: %" PRIu32
			   ", HTF: %7.0f, " "learnings: %7" PRIu32
			   ", hits: %7.0f, " "Pc: %6.4e\n",
			   window_idx, class_idx, htf,
			   class[class_idx].header->learnings,
			   class[class_idx].hits, ptc[class_idx]);
		}
	    }
#endif
	  }
      }
    }


  /* find class with max probability and close all open files */
  {
    int max_ptc_idx = 0;
    double max_ptc = 0;
    OSBF_HEADER_STRUCT header;

    for (class_idx = 0; class_idx < num_classes; class_idx++)
      {
	if (ptc[class_idx] > max_ptc)
	  {
	    max_ptc_idx = class_idx;
	    max_ptc = ptc[class_idx];
	  }
	err = osbf_close_class (&class[class_idx], errmsg);
      }

    if (err == 0 && (flags & COUNT_CLASSIFICATIONS))
      {
	int fd;

	fd = open (class[max_ptc_idx].classname, O_RDWR);
	if (fd >= 0)
	  {
	    if (osbf_lock_file (fd, 0, sizeof (header)) == 0)
	      {
		read (fd, &header, sizeof (header));
		header.classifications += 1;
		lseek (fd, 0, SEEK_SET);
		write (fd, &header, sizeof (header));

		if (osbf_unlock_file (fd, 0, sizeof (header)) != 0)
		  {
		    snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
			      "Couldn't Unlock file: %s.",
			      class[max_ptc_idx].classname);
		    err = -1;
		  }
	      }
	    /* for now, ignore if file couldn't be locked */
	    close (fd);
	  }
	else
	  {
	    snprintf (errmsg, OSBF_ERROR_MESSAGE_LEN,
		      "Couldn't open file RDWR for locking: %s.",
		      class[max_ptc_idx].classname);
	  }
	/* for now, ignore if file couldn't be locked */
      }
  }

#if (DEBUG)
  {
    for (class_idx = 0; class_idx < num_classes; class_idx++)
      fprintf (stderr,
	       "Probability of match for file %" PRIu32 ": %f\n",
	       class_idx, ptc[class_idx]);
  }
#endif

  return (err);
}
