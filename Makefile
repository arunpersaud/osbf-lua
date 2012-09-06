T= osbf

include ./config

DIST_DIR= osbf-$LIB_VERSION
TAR_FILE= $(DIST_DIR).tar.gz
ZIP_FILE= $(DIST_DIR).zip
LIBNAME= lib$T$(LIB_EXT).$(LIB_VERSION)

SRCS= losbflib.c osbf_bayes.c osbf_aux.c
OBJS= losbflib.o osbf_bayes.o osbf_aux.o


lib: $(LIBNAME)

*.o:	*.c osbflib.h config

$(LIBNAME): $(OBJS)
	$(CC) $(CFLAGS) $(LIB_OPTION) -o $(LIBNAME) $(OBJS) $(LIBS)

install: $(LIBNAME)
	mkdir -p $(LUA_LIBDIR)
	strip $(LIBNAME)
	cp $(LIBNAME) $(LUA_LIBDIR)
	(cd $(LUA_LIBDIR) ; rm -f $T$(LIB_EXT) ; ln -fs $(LIBNAME) $T$(LIB_EXT))

install_spamfilter:
	mkdir -p $(SPAMFILTER_DIR)
	cp spamfilter/* $(SPAMFILTER_DIR)
	chmod 755 $(SPAMFILTER_DIR)/*.lua

clean:
	rm -f $L $(LIBNAME) $(OBJS) *.so *~ spamfilter/*~

