/*
 * OSBF-Lua - library for text classification
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

#include <ctype.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <math.h>
#include <errno.h>
#include <dirent.h>
#include <inttypes.h>

#include "lua.h"

#include "lauxlib.h"
#include "lualib.h"

#include "osbflib.h"

extern int luaopen_osbf (lua_State * L);

/* configurable constants */
extern uint32_t microgroom_chain_length;
extern uint32_t microgroom_stop_after;
extern double K1, K2, K3;
extern uint32_t max_token_size, max_long_tokens;
extern uint32_t limit_token_size;

/* macro to `unsign' a character */
#ifndef uchar
#define uchar(c)        ((unsigned char)(c))
#endif

/* db key names */
static char key_classes[] = "classes";
static char key_ncfs[] = "ncfs";
static char key_delimiters[] = "delimiters";

/* pR scale calibration factor - pR_SCF
   This value is used to calibrate the pR scale so that
   values in the interval [-20, 20] indicate the need
   of reinforcement training, even if the classification 
   is correct.
   The default pR_SCF was determined experimentally,
   but can be changed using the osbf.config call.
   
*/
static double pR_SCF = 0.59;

/**********************************************************/

static int
lua_osbf_config (lua_State * L)
{
  int options_set = 0;

  luaL_checktype (L, 1, LUA_TTABLE);

  lua_pushstring (L, "max_chain");
  lua_gettable (L, 1);
  if (lua_isnumber (L, -1))
    {
      microgroom_chain_length = luaL_checknumber (L, -1);
      options_set++;
    }
  lua_pop (L, 1);

  lua_pushstring (L, "stop_after");
  lua_gettable (L, 1);
  if (lua_isnumber (L, -1))
    {
      microgroom_stop_after = luaL_checknumber (L, -1);
      options_set++;
    }
  lua_pop (L, 1);

  lua_pushstring (L, "K1");
  lua_gettable (L, 1);
  if (lua_isnumber (L, -1))
    {
      K1 = luaL_checknumber (L, -1);
      options_set++;
    }
  lua_pop (L, 1);

  lua_pushstring (L, "K2");
  lua_gettable (L, 1);
  if (lua_isnumber (L, -1))
    {
      K2 = luaL_checknumber (L, -1);
      options_set++;
    }
  lua_pop (L, 1);

  lua_pushstring (L, "K3");
  lua_gettable (L, 1);
  if (lua_isnumber (L, -1))
    {
      K3 = luaL_checknumber (L, -1);
      options_set++;
    }
  lua_pop (L, 1);

  lua_pushstring (L, "limit_token_size");
  lua_gettable (L, 1);
  if (lua_isnumber (L, -1))
    {
      limit_token_size = luaL_checknumber (L, -1);
      options_set++;
    }
  lua_pop (L, 1);

  lua_pushstring (L, "max_token_size");
  lua_gettable (L, 1);
  if (lua_isnumber (L, -1))
    {
      max_token_size = luaL_checknumber (L, -1);
      options_set++;
    }
  lua_pop (L, 1);

  lua_pushstring (L, "max_long_tokens");
  lua_gettable (L, 1);
  if (lua_isnumber (L, -1))
    {
      max_long_tokens = luaL_checknumber (L, -1);
      options_set++;
    }
  lua_pop (L, 1);

  lua_pushstring (L, "pR_SCF");
  lua_gettable (L, 1);
  if (lua_isnumber (L, -1))
    {
      pR_SCF = luaL_checknumber (L, -1);
      options_set++;
    }
  lua_pop (L, 1);

  lua_pushnumber (L, (lua_Number) options_set);
  return 1;
}

/**********************************************************/

static int
lua_osbf_createdb (lua_State * L)
{
  const char *cfcname;
  uint32_t buckets;
  uint32_t minor = 0;
  char errmsg[OSBF_ERROR_MESSAGE_LEN] = { '\0' };
  int32_t num_classes;

  /* check if the second arg is a table */
  luaL_checktype (L, 1, LUA_TTABLE);

  /* get the number of classes to create */
  num_classes = luaL_getn (L, 1);

  /* get number of buckets */
  buckets = luaL_checknumber (L, 2);

  lua_pushnil (L);		/* first key */
  while (lua_next (L, 1) != 0)
    {
      cfcname = luaL_checkstring (L, -1);
      lua_pop (L, 1);

      if (osbf_create_cfcfile (cfcname, buckets, OSBF_VERSION,
			       minor, errmsg) != EXIT_SUCCESS)
	{
	  num_classes = -1;
	  break;
	}
    }

  if (num_classes >= 0)
    lua_pushnumber (L, (lua_Number) num_classes);
  else
    lua_pushnil (L);
  lua_pushstring (L, errmsg);
  return 2;
}

/**********************************************************/

/* removes all classes (files) in a database */
/* returns the number of files removed or error */
/* and the number of the last file removed */
static int
lua_osbf_removedb (lua_State * L)
{
  const char *cfcname;
  char errmsg[OSBF_ERROR_MESSAGE_LEN] = { '\0' };
  int num_classes;
  int save_errno, removed;

  /* check if the second arg is a table */
  luaL_checktype (L, 1, LUA_TTABLE);

  /* get the number of classes to remove */
  num_classes = luaL_getn (L, 1);
  removed = 0;
  lua_pushnil (L);		/* first key */
  while (lua_next (L, 1) != 0)
    {
      cfcname = luaL_checkstring (L, -1);
      lua_pop (L, 1);
      if (remove (cfcname) == 0)
	removed++;
      else
	{
	  save_errno = errno;
	  strncat (errmsg, cfcname, OSBF_ERROR_MESSAGE_LEN);
	  strncat (errmsg, ": ", OSBF_ERROR_MESSAGE_LEN);
	  /* append err message after file name */
	  strncat (errmsg, strerror (save_errno), OSBF_ERROR_MESSAGE_LEN);
	  break;
	}
    }

  if (errmsg[0] != '\0')
    {
      lua_pushnil (L);
      lua_pushstring (L, errmsg);
      return 2;
    }
  else
    {
      /* return the number of files deleted */
      lua_pushnumber (L, (lua_Number) removed);
      return 1;
    }
}

/**********************************************************/

static int
lua_osbf_classify (lua_State * L)
{
  const unsigned char *text;
  size_t text_len;
  const char *delimiters;	/* extra token delimiters */
  size_t delimiters_len;
  const char *classes[OSBF_MAX_CLASSES + 1];	/* set of classes */
  unsigned ncfs;		/* defines a partition with 2 subsets of the set    */
  /* "classes". The first "ncfs" classes form the  */
  /* first subset. The others form the second one.          */
  uint32_t flags = 0;		/* default value */
  double min_p_ratio;		/* min pmax/p,in ratio */
  /* class probabilities are returned in p_classes */
  double p_classes[OSBF_MAX_CLASSES];
  uint32_t p_trainings[OSBF_MAX_CLASSES];
  char errmsg[OSBF_ERROR_MESSAGE_LEN] = { '\0' };
  unsigned i, i_pmax, num_classes;
  double p_first_subset, p_second_subset;

  /* get text pointer and text len */
  text = (unsigned char *) luaL_checklstring (L, 1, &text_len);

  /* check if the second arg is a table */
  luaL_checktype (L, 2, LUA_TTABLE);

  /* extract the class table from inside the db table */
  lua_pushstring (L, key_classes);
  lua_gettable (L, 2);

  /* extract the classes */
  /* check if the arg in the top is a table */
  luaL_checktype (L, -1, LUA_TTABLE);
  lua_pushnil (L);
  num_classes = 0;
  while (num_classes < OSBF_MAX_CLASSES && lua_next (L, -2) != 0)
    {
      classes[num_classes++] = luaL_checkstring (L, -1);
      lua_pop (L, 1);
    }
  classes[num_classes] = NULL;
  /* remove last index of the class table and the table itself */
  lua_pop (L, 1);
  if (num_classes < 1)
    return luaL_error (L, "at least one class must be given");

  /* extract the number of classes in the first subset */

  lua_pushstring (L, key_ncfs);
  lua_gettable (L, 2);
  ncfs = luaL_checknumber (L, -1);
  lua_pop (L, 1);
  if (ncfs > num_classes)
    ncfs = num_classes;

  /* extract the extra token delimiters */
  lua_pushstring (L, key_delimiters);
  lua_gettable (L, 2);
  delimiters = luaL_checklstring (L, -1, &delimiters_len);
  lua_pop (L, 1);

  /* extract flags, if any */
  flags = (uint32_t) luaL_optnumber (L, 3, 0);
  /* extract p_min_ratio if any */
  min_p_ratio = (double) luaL_optnumber (L, 4, OSBF_MIN_PMAX_PMIN_RATIO);

  /* call osbf_classify */
  if (osbf_bayes_classify (text, text_len, delimiters, classes,
			   flags, min_p_ratio, p_classes, p_trainings,
			   errmsg) < 0)
    {
      lua_pushnil (L);
      lua_pushstring (L, errmsg);
      return 2;
    }
  else
    {
      lua_newtable (L);
      i_pmax = 0;
      p_first_subset = p_second_subset = 10 * DBL_MIN;
      for (i = 0; i < num_classes; i++)
	{
	  lua_pushnumber (L, (lua_Number) p_classes[i]);
	  lua_rawseti (L, -2, i + 1);
	  if (p_classes[i] > p_classes[i_pmax])
	    i_pmax = i;
	  if (i < ncfs)
	    p_first_subset += p_classes[i];
	  else
	    p_second_subset += p_classes[i];
	}

      /*
       * return pR, log10 of the ratio between the sum of the
       * probabilities in the first subset and the sum of the
       * probabilities in the second one.
       */
      lua_pushnumber (L,
		      (lua_Number) pR_SCF *
		      log10 (p_first_subset / p_second_subset));

      /* exchange array and pR positions on the stack */
      lua_insert (L, -2);

      /* return index to the class with highest probability */
      lua_pushnumber (L, (lua_Number) i_pmax + 1);

      /* push table with number of trainings per class */
      lua_newtable (L);
      for (i = 0; i < num_classes; i++)
	{
	  lua_pushnumber (L, (lua_Number) p_trainings[i]);
	  lua_rawseti (L, -2, i + 1);
	}
    }

  return 4;
}

/**********************************************************/

static int
osbf_train (lua_State * L, int sense)
{
  const unsigned char *text;
  size_t text_len;
  const char *delimiters;	/* extra token delimiters */
  size_t delimiters_len;
  const char *classes[OSBF_MAX_CLASSES + 1];
  int num_classes;
  size_t ctbt;			/* index of the class to be trained */
  uint32_t flags = 0;		/* default value */
  char errmsg[OSBF_ERROR_MESSAGE_LEN] = { '\0' };

  /* get text pointer and text len */
  text = (unsigned char *) luaL_checklstring (L, 1, &text_len);

  /* check if the second arg is a table */
  luaL_checktype (L, 2, LUA_TTABLE);
  /* extract the class table from inside the db table */
  lua_pushstring (L, key_classes);
  lua_gettable (L, 2);

  /* extract the classes */
  /* check if the arg in the top is a table */
  luaL_checktype (L, -1, LUA_TTABLE);
  lua_pushnil (L);
  num_classes = 0;
  while (num_classes < OSBF_MAX_CLASSES && lua_next (L, -2) != 0)
    {
      classes[num_classes++] = luaL_checkstring (L, -1);
      lua_pop (L, 1);
    }
  classes[num_classes] = NULL;
  /* remove last index of the class table and the table itself */
  lua_pop (L, 1);
  if (num_classes < 1)
    return luaL_error (L, "at least one class must be given");

  /* extract the extra token delimiters */
  lua_pushstring (L, key_delimiters);
  lua_gettable (L, 2);
  delimiters = luaL_checklstring (L, -1, &delimiters_len);
  lua_pop (L, 1);

  /* get the index of the class to be trained */
  ctbt = luaL_checknumber (L, 3) - 1;

  /* get flags  */
  if (lua_isnumber (L, 4))
    flags = (uint32_t) luaL_checknumber (L, 4);

  if (osbf_bayes_learn (text, text_len, delimiters, classes,
			ctbt, sense, flags, errmsg) < 0)
    {
      lua_pushnil (L);
      lua_pushstring (L, errmsg);
      return 2;
    }
  else
    {
      lua_pushboolean (L, 1);
      return 1;
    }
}

/**********************************************************/

static int
lua_osbf_learn (lua_State * L)
{
  return osbf_train (L, 1);
}

/**********************************************************/

static int
lua_osbf_unlearn (lua_State * L)
{
  return osbf_train (L, -1);
}

/**********************************************************/

static int
lua_osbf_dump (lua_State * L)
{
  const char *cfcfile, *csvfile;
  char errmsg[OSBF_ERROR_MESSAGE_LEN];

  cfcfile = luaL_checkstring (L, 1);
  csvfile = luaL_checkstring (L, 2);

  if (osbf_dump (cfcfile, csvfile, errmsg) == 0)
    {
      lua_pushboolean (L, 1);
      return 1;
    }
  else
    {
      lua_pushnil (L);
      lua_pushstring (L, errmsg);
      return 2;
    }
}

/**********************************************************/

static int
lua_osbf_restore (lua_State * L)
{
  const char *cfcfile, *csvfile;
  char errmsg[OSBF_ERROR_MESSAGE_LEN];

  cfcfile = luaL_checkstring (L, 1);
  csvfile = luaL_checkstring (L, 2);

  if (osbf_restore (cfcfile, csvfile, errmsg) == 0)
    {
      lua_pushboolean (L, 1);
      return 1;
    }
  else
    {
      lua_pushnil (L);
      lua_pushstring (L, errmsg);
      return 2;
    }
}

/**********************************************************/

static int
lua_osbf_import (lua_State * L)
{
  const char *cfcfile, *csvfile;
  char errmsg[OSBF_ERROR_MESSAGE_LEN];

  cfcfile = luaL_checkstring (L, 1);
  csvfile = luaL_checkstring (L, 2);

  if (osbf_import (cfcfile, csvfile, errmsg) == 0)
    {
      lua_pushboolean (L, 1);
      return 1;
    }
  else
    {
      lua_pushnil (L);
      lua_pushstring (L, errmsg);
      return 2;
    }
}

/**********************************************************/

static int
lua_osbf_stats (lua_State * L)
{

  const char *cfcfile;
  STATS_STRUCT class;
  char errmsg[OSBF_ERROR_MESSAGE_LEN];
  int full = 1;

  cfcfile = luaL_checkstring (L, 1);
  if (lua_isboolean (L, 2))
    {
      full = lua_toboolean (L, 2);
    }

  if (osbf_stats (cfcfile, &class, errmsg, full) == 0)
    {
      lua_newtable (L);

      lua_pushliteral (L, "version");
      lua_pushnumber (L, (lua_Number) class.version);
      lua_settable (L, -3);

      lua_pushliteral (L, "buckets");
      lua_pushnumber (L, (lua_Number) class.total_buckets);
      lua_settable (L, -3);

      lua_pushliteral (L, "bucket_size");
      lua_pushnumber (L, (lua_Number) class.bucket_size);
      lua_settable (L, -3);

      lua_pushliteral (L, "header_size");
      lua_pushnumber (L, (lua_Number) class.header_size);
      lua_settable (L, -3);

      lua_pushliteral (L, "learnings");
      lua_pushnumber (L, (lua_Number) class.learnings);
      lua_settable (L, -3);

      lua_pushliteral (L, "extra_learnings");
      lua_pushnumber (L, (lua_Number) class.extra_learnings);
      lua_settable (L, -3);

      lua_pushliteral (L, "mistakes");
      lua_pushnumber (L, (lua_Number) class.mistakes);
      lua_settable (L, -3);

      lua_pushliteral (L, "classifications");
      lua_pushnumber (L, (lua_Number) class.classifications);
      lua_settable (L, -3);

      if (full == 1)
	{
	  lua_pushliteral (L, "chains");
	  lua_pushnumber (L, (lua_Number) class.num_chains);
	  lua_settable (L, -3);

	  lua_pushliteral (L, "max_chain");
	  lua_pushnumber (L, (lua_Number) class.max_chain);
	  lua_settable (L, -3);

	  lua_pushliteral (L, "avg_chain");
	  lua_pushnumber (L, (lua_Number) class.avg_chain);
	  lua_settable (L, -3);

	  lua_pushliteral (L, "max_displacement");
	  lua_pushnumber (L, (lua_Number) class.max_displacement);
	  lua_settable (L, -3);

	  lua_pushliteral (L, "unreachable");
	  lua_pushnumber (L, (lua_Number) class.unreachable);
	  lua_settable (L, -3);

	  lua_pushliteral (L, "used_buckets");
	  lua_pushnumber (L, (lua_Number) class.used_buckets);
	  lua_settable (L, -3);

	  lua_pushliteral (L, "use");
	  if (class.total_buckets > 0)
	    lua_pushnumber (L, (lua_Number) ((double) class.used_buckets /
					     class.total_buckets));
	  else
	    lua_pushnumber (L, (lua_Number) 100);
	  lua_settable (L, -3);
	}

      return 1;
    }
  else
    {
      lua_pushnil (L);
      lua_pushstring (L, errmsg);
      return 2;
    }
}

/**********************************************************/

/*
** Assumes the table is on top of the stack.
*/
static void
set_info (lua_State * L)
{
  lua_pushliteral (L, "_COPYRIGHT");
  lua_pushliteral (L, "Copyright (C) 2005, 2006 Fidelis Assis");
  lua_settable (L, -3);
  lua_pushliteral (L, "_DESCRIPTION");
  lua_pushliteral (L, "OSBF-Lua is a Lua library for text classification.");
  lua_settable (L, -3);
  lua_pushliteral (L, "_NAME");
  lua_pushliteral (L, "OSBF-Lua");
  lua_settable (L, -3);
  lua_pushliteral (L, "_VERSION");
  lua_pushliteral (L, LIB_VERSION);
  lua_settable (L, -3);
}

/**********************************************************/

/* auxiliary functions */

#define MAX_DIR_SIZE 256

static int
lua_osbf_changedir (lua_State * L)
{
  const char *newdir = luaL_checkstring (L, 1);

  if (chdir (newdir) != 0)
    {
      lua_pushboolean (L, 1);
      return 1;
    }
  else
    {
      lua_pushnil (L);
      lua_pushfstring (L, "can't change dir to '%s'\n", newdir);
      return 2;
    }
}

/**********************************************************/

static int
lua_osbf_getdir (lua_State * L)
{
  char cur_dir[MAX_DIR_SIZE + 1];

  if (getcwd (cur_dir, MAX_DIR_SIZE) != NULL)
    {
      lua_pushstring (L, cur_dir);
      return 1;
    }
  else
    {
      lua_pushnil (L);
      lua_pushstring (L, "can't get current dir");
      return 2;
    }
}

/**********************************************************/
/* Directory Iterator - from the PIL book */

/* forward declaration for the iterator function */
static int dir_iter (lua_State * L);

static int
l_dir (lua_State * L)
{
  const char *path = luaL_checkstring (L, 1);

  /* create a userdatum to store a DIR address */
  DIR **d = (DIR **) lua_newuserdata (L, sizeof (DIR *));

  /* set its metatable */
  luaL_getmetatable (L, "LuaBook.dir");
  lua_setmetatable (L, -2);

  /* try to open the given directory */
  *d = opendir (path);
  if (*d == NULL)		/* error opening the directory? */
    luaL_error (L, "cannot open %s: %s", path, strerror (errno));

  /* creates and returns the iterator function
     (its sole upvalue, the directory userdatum,
     is already on the stack top */
  lua_pushcclosure (L, dir_iter, 1);
  return 1;
}

static int
dir_iter (lua_State * L)
{
  DIR *d = *(DIR **) lua_touserdata (L, lua_upvalueindex (1));
  struct dirent *entry;
  if ((entry = readdir (d)) != NULL)
    {
      lua_pushstring (L, entry->d_name);
      return 1;
    }
  else
    return 0;			/* no more values to return */
}

static int
dir_gc (lua_State * L)
{
  DIR *d = *(DIR **) lua_touserdata (L, 1);
  if (d)
    closedir (d);
  return 0;
}

/**********************************************************/

static const struct luaL_reg osbf[] = {
  {"create_db", lua_osbf_createdb},
  {"remove_db", lua_osbf_removedb},
  {"config", lua_osbf_config},
  {"classify", lua_osbf_classify},
  {"learn", lua_osbf_learn},
  {"unlearn", lua_osbf_unlearn},
  {"dump", lua_osbf_dump},
  {"restore", lua_osbf_restore},
  {"import", lua_osbf_import},
  {"stats", lua_osbf_stats},
  {"getdir", lua_osbf_getdir},
  {"chdir", lua_osbf_changedir},
  {"dir", l_dir},
  {NULL, NULL}
};


/*
** Open OSBF library
*/
int
luaopen_osbf (lua_State * L)
{
  /* Open dir function */
  luaL_newmetatable (L, "LuaBook.dir");
  /* set its __gc field */
  lua_pushstring (L, "__gc");
  lua_pushcfunction (L, dir_gc);
  lua_settable (L, -3);

  luaL_register (L, "osbf", osbf);
  set_info (L);
  return 1;
}
