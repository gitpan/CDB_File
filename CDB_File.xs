/*

Most of this is reasonably straightforward.  The complications arise
when we are "iterating" over the CDB file, that is to say, using `keys'
or `values' or `each' to retrieve all the data in the file in order.
This interface stores extra data to allow us to track iterations: end
is a pointer to the end of data in the CDB file, and also a flag which
indicates whether we are iterating or not (note that the end of data
occurs at a position >= 2048); curkey is a copy of the current key;
curpos is the file offset of curkey; and fetch_advance is 0 for

    FIRSTKEY, fetch, NEXTKEY, fetch, NEXTKEY, fetch, ...

but 1 for

    FIRSTKEY, NEXTKEY, NEXTKEY, ..., fetch, fetch, fetch, ...

Don't tell the OO Police, but there are actually two different objects
called CDB_File.  One is created by TIEHASH, and accessed by the usual
tied hash methods (FETCH, FIRSTKEY, etc.).  The other is created by new,
and accessed by insert and finish.

In both cases, the object is a blessed reference to a scalar.  The
scalar contains either a struct cdbobj or a struct cdbmakeobj.

It gets a little messy in DESTROY: since this method will automatically
be called for both sorts of object, it distinguishes them by their
different sizes.

*/

#ifdef __cplusplus
extern "C" {
#endif

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <sys/stat.h>
#include <sys/types.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

#ifdef HASMMAP
#include <sys/mman.h>
#endif

/* We need to whistle up an error number for a file that is not a CDB
file.  The BSDish EFTYPE probably gives the most useful error message;
failing that we'll settle for the Single Unix Specification v2 EPROTO;
and finally the rather inappropriate, but universally(?) implemented,
EINVAL. */
#ifdef EFTYPE
#else
#ifdef EPROTO
#define EFTYPE EPROTO
#else
#define EFTYPE EINVAL
#endif
#endif

/* These two provide backwards compatibility with perl 5.005. */
#ifndef WARN_UNINITIALIZED
#define ckWARN(x) dowarn
#define report_uninit() warn(warn_uninit)
#endif

#ifdef __cplusplus
}
#endif

struct cdb {
	GV *glob;   /* */

#ifdef HASMMAP
	char *map;
#endif

	U32 end;    /* If non zero, the file offset of the first byte of hash tables. */
	SV *curkey; /* While iterating: a copy of the current key; */
	U32 curpos; /*                  the file offset of the current record. */
	int fetch_advance; /* the kludge */
	U32 size; /* initialized if map is nonzero */
	U32 loop; /* number of hash slots searched under this key */
	U32 khash; /* initialized if loop is nonzero */
	U32 kpos; /* initialized if loop is nonzero */
	U32 hpos; /* initialized if loop is nonzero */
	U32 hslots; /* initialized if loop is nonzero */
	U32 dpos; /* initialized if cdb_findnext() returns 1 */
	U32 dlen; /* initialized if cdb_findnext() returns 1 */
} ;

#define CDB_HPLIST 1000

struct cdb_hp { U32 h; U32 p; } ;

struct cdb_hplist {
	struct cdb_hp hp[CDB_HPLIST];
	struct cdb_hplist *next;
	int num;
} ;

struct cdb_make {
	PerlIO *f;            /* Handle of file being created. */
	char *fn;             /* Final name of file. */
	char *fntemp;         /* Temporary name of file. */
	char final[2048];
	char bspace[1024];
	U32 count[256];
	U32 start[256];
	struct cdb_hplist *head;
	struct cdb_hp *split; /* includes space for hash */
	struct cdb_hp *hash;
	U32 numentries;
	U32 pos;
	int fd;
} ;

static void writeerror() { croak("Write to CDB_File failed: %s", Strerror(errno)); }

static void readerror() { croak("Read of CDB_File failed: %s", Strerror(errno)); }

static void seekerror() { croak("Seek in CDB_File failed: %s", Strerror(errno)); }

static void nomem() { croak("Out of memory!"); }

static int cdb_make_start(struct cdb_make *c) {
	c->head = 0;
	c->split = 0;
	c->hash = 0;
	c->numentries = 0;
	c->pos = sizeof c->final;
	return PerlIO_seek(c->f, c->pos, SEEK_SET);
}

static int posplus(struct cdb_make *c, U32 len) {
	U32 newpos = c->pos + len;
	if (newpos < len) { errno = ENOMEM; return -1; }
	c->pos = newpos;
	return 0;
}

static int cdb_make_addend(struct cdb_make *c, unsigned int keylen, unsigned int datalen, U32 h) {
	struct cdb_hplist *head;

	head = c->head;
	if (!head || (head->num >= CDB_HPLIST)) {
		New(0xCDB, head, 1, struct cdb_hplist);
		head->num = 0;
		head->next = c->head;
		c->head = head;
	}
	head->hp[head->num].h = h;
	head->hp[head->num].p = c->pos;
	++head->num;
	++c->numentries;
	if (posplus(c, 8) == -1) return -1;
	if (posplus(c, keylen) == -1) return -1;
	if (posplus(c, datalen) == -1) return -1;
	return 0;
}

#define CDB_HASHSTART 5381

static U32 cdb_hashadd(U32 h, unsigned char c) {
	h += (h << 5);
	return h ^ c;
}

static U32 cdb_hash(char *buf, unsigned int len) {
	U32 h;

	h = CDB_HASHSTART;
	while (len) {
		h = cdb_hashadd(h,*buf++);
		--len;
	}
	return h;
}

static void uint32_pack(char s[4], U32 u) {
	s[0] = u & 255;
	u >>= 8;
	s[1] = u & 255;
	u >>= 8;
	s[2] = u & 255;
	s[3] = u >> 8;
}

static void uint32_unpack(char s[4], U32 *u) {
	U32 result;

	result = (unsigned char) s[3];
	result <<= 8;
	result += (unsigned char) s[2];
	result <<= 8;
	result += (unsigned char) s[1];
	result <<= 8;
	result += (unsigned char) s[0];

	*u = result;
}

static void cdb_findstart(struct cdb *c) {
	c->loop = 0;
}

static int cdb_read(struct cdb *c, char *buf, unsigned int len, U32 pos) {

#ifdef HASMMAP
	if (c->map) {
		if ((pos > c->size) || (c->size - pos < len)) {
			errno = EFTYPE;
			return -1;
		}
		memcpy(buf, c->map + pos, len);
		return 0;
	}
#endif

	if (PerlIO_seek(IoIFP(GvIOn(c->glob)), pos, SEEK_SET) == -1) return -1;
	while (len > 0) {
		int r;
		do
			r = PerlIO_read(IoIFP(GvIOn(c->glob)), buf, len);
		while ((r == -1) && (errno == EINTR));
		if (r == -1) return -1;
		if (r == 0) {
			errno = EFTYPE;
			return -1;
		}
		buf += r;
		len -= r;
	}
	return 0;
}

static int match(struct cdb *c,char *key,unsigned int len, U32 pos) {
	char buf[32];
	int n;

	while (len > 0) {
		n = sizeof buf;
		if (n > len) n = len;
		if (cdb_read(c, buf, n, pos) == -1) return -1;
		if (memcmp(buf, key, n)) return 0;
		pos += n;
		key += n;
		len -= n;
	}
	return 1;
}

int cdb_findnext(struct cdb *c,char *key,unsigned int len) {
	char buf[8];
	U32 pos;
	U32 u;

  if (!c->loop) {
    u = cdb_hash(key,len);
    if (cdb_read(c,buf,8,(u << 3) & 2047) == -1) return -1;
    uint32_unpack(buf + 4,&c->hslots);
    if (!c->hslots) return 0;
    uint32_unpack(buf,&c->hpos);
    c->khash = u;
    u >>= 8;
    u %= c->hslots;
    u <<= 3;
    c->kpos = c->hpos + u;
  }

  while (c->loop < c->hslots) {
    if (cdb_read(c,buf,8,c->kpos) == -1) return -1;
    uint32_unpack(buf + 4,&pos);
    if (!pos) return 0;
    c->loop += 1;
    c->kpos += 8;
    if (c->kpos == c->hpos + (c->hslots << 3)) c->kpos = c->hpos;
    uint32_unpack(buf,&u);
    if (u == c->khash) {
      if (cdb_read(c,buf,8,pos) == -1) return -1;
      uint32_unpack(buf,&u);
      if (u == len)
	switch(match(c,key,len,pos + 8)) {
	  case -1:
	    return -1;
	  case 1:
	    uint32_unpack(buf + 4,&c->dlen);
	    c->dpos = pos + 8 + len;
	    return 1;
	}
    }
  }

  return 0;
}

static int cdb_find(struct cdb *c, char *key, unsigned int len) {
  cdb_findstart(c);
  return cdb_findnext(c,key,len);
}

static void iter_start(struct cdb *c) {
	char buf[4];

	c->curpos = 2048;
	if (cdb_read(c, buf, 4, 0) == -1) readerror();
	uint32_unpack(buf, &c->end);
	c->curkey = NEWSV(0xcdb, 1);
	c->fetch_advance = 0;
}

static int iter_key(struct cdb *c) {
	char buf[8];
	U32 klen;

	if (c->curpos < c->end) {
		if (cdb_read(c, buf, 8, c->curpos) == -1) readerror();
		uint32_unpack(buf, &klen);
		(void)SvPOK_only(c->curkey);
		SvGROW(c->curkey, klen); SvCUR_set(c->curkey, klen);
		if (cdb_read(c, SvPVX(c->curkey), klen, c->curpos + 8) == -1) readerror();
		return 1;
	}
	return 0;
}

static void iter_advance(struct cdb *c) {
	char buf[8];
	U32 klen, dlen;

	if (cdb_read(c, buf, 8, c->curpos) == -1) readerror();
	uint32_unpack(buf, &klen);
	uint32_unpack(buf + 4, &dlen);
	c->curpos += 8 + klen + dlen;
}

static void iter_end(struct cdb *c) {
	if (c->end != 0) {
		c->end = 0;
		SvREFCNT_dec(c->curkey);
	}
}

#define cdb_datapos(c) ((c)->dpos)
#define cdb_datalen(c) ((c)->dlen)

MODULE = CDB_File		PACKAGE = CDB_File	PREFIX = cdb_

 # Some accessor methods.

 # WARNING: I don't really understand enough about Perl's guts (file
 # handles / globs, etc.) to write this code.  I think this is right, and
 # it seems to work, but input from anybody with a deeper
 # understanding would be most welcome.

SV *
cdb_handle(db)
	SV *		db
	
	PROTOTYPE: $

	PREINIT:
	struct cdb *this;

	CODE:
	this = (struct cdb *)SvPV(SvRV(db), PL_na);
	RETVAL = newRV_inc((SV *)GvIOn(this->glob));

	OUTPUT:
		RETVAL

U32
cdb_datalen(db)
	SV *		db

	PROTOTYPE: $

	CODE:
	RETVAL = cdb_datalen((struct cdb *)SvPV(SvRV(db), PL_na));

	OUTPUT:
	RETVAL

U32
cdb_datapos(db)
	SV *		db

	PROTOTYPE: $

	CODE:
	RETVAL = cdb_datapos((struct cdb *)SvPV(SvRV(db), PL_na));

	OUTPUT:
	RETVAL

SV *
cdb_TIEHASH(dbtype, filename)
	char *		dbtype
	char *		filename

	PROTOTYPE: $$

	CODE:
	PerlIO *f;
	IO *io;
	struct cdb cdb;
	SV *cdbp;

	f = PerlIO_open(filename, "rb");
	if (!f) XSRETURN_NO;
	cdb.glob = newGVgen("cdb");
	io = GvIOn(cdb.glob);
	IoIFP(io) = f;
	cdb.end = 0;
#ifdef HASMMAP
	{
		struct stat st;
		int fd = PerlIO_fileno(f);

		cdb.map = 0;
		if (fstat(fd, &st) == 0) {
			if (st.st_size <= 0xffffffff) {
				char *x;

				x = mmap(0, st.st_size, PROT_READ, MAP_SHARED, fd, 0);
				if (x != (char *)-1) {
					cdb.size = st.st_size;
					cdb.map = x;
				}
			}
		}
	}
#endif
	cdbp = newSVpv((char *)&cdb, sizeof(struct cdb));
	RETVAL = newRV_noinc(cdbp);
	sv_bless(RETVAL, gv_stashpv(dbtype, 0));
	/* Prevent the user stomping on the cdb. */
	SvREADONLY_on(cdbp);

	OUTPUT:
		RETVAL

SV *
cdb_FETCH(db, k)
	SV *		db
	SV *		k
	
	PROTOTYPE: $$

	PREINIT:
	struct cdb *this;
	PerlIO *f;
	char buf[8];
	int found;
	off_t pos;
	STRLEN klen, x;
	U32 klen0;
	char *kp;

	CODE:
	if (!SvOK(k)) {
		if (ckWARN(WARN_UNINITIALIZED)) report_uninit();
		XSRETURN_UNDEF;
	}
	this = (struct cdb *)SvPV(SvRV(db), PL_na);
	kp = SvPV(k, klen);
	if (this->end && sv_eq(this->curkey, k)) {
		if (cdb_read(this, buf, 8, this->curpos) == -1) readerror();
		uint32_unpack(buf + 4, &this->dlen);
		this->dpos = this->curpos + 8 + klen;
		if (this->fetch_advance) {
			iter_advance(this);
			if (!iter_key(this)) iter_end(this);
		}
		found = 1;
	} else {
		cdb_findstart(this);
		found = cdb_findnext(this, kp, klen);
		if ((found != 0) && (found != 1)) readerror();
	}
	ST(0) = sv_newmortal();
	if (found && sv_upgrade(ST(0), SVt_PV)) {
		U32 dlen = cdb_datalen(this);

		(void)SvPOK_only(ST(0));
		SvGROW(ST(0), dlen + 1); SvCUR_set(ST(0),  dlen);
		if (cdb_read(this, SvPVX(ST(0)), dlen, cdb_datapos(this)) == -1) readerror();
		SvPV(ST(0), PL_na)[dlen] = '\0';
	}

AV *
cdb_multi_get(db, k)
	SV *		db
	SV *		k
	
	PROTOTYPE: $$

	PREINIT:
	struct cdb *this;
	PerlIO *f;
	char buf[8];
	int found;
	off_t pos;
	STRLEN klen;
	U32 dlen, klen0;
	char *kp;
	SV *x;

	CODE:
	if (!SvOK(k)) {
		if (ckWARN(WARN_UNINITIALIZED)) report_uninit();
		XSRETURN_UNDEF;
	}
	this = (struct cdb *)SvPV(SvRV(db), PL_na);
	cdb_findstart(this);
	RETVAL = newAV();
	sv_2mortal((SV *)RETVAL);
	kp = SvPV(k, klen);
	for (;;) {
		found = cdb_findnext(this, kp, klen);
		if ((found != 0) && (found != 1)) readerror();
		if (!found) break;
		x = newSVpvn("", 0);
		dlen = cdb_datalen(this);
		SvGROW(x, dlen + 1); SvCUR_set(x,  dlen);
		if (cdb_read(this, SvPVX(x), dlen, cdb_datapos(this)) == -1) readerror();
		SvPV(x, PL_na)[dlen] = '\0';
		av_push(RETVAL, x);
	}

	OUTPUT:
		RETVAL

int
cdb_EXISTS(db, k)
	SV *		db
	SV *		k

	PROTOTYPE: $$

	CODE:
	struct cdb *this;
	STRLEN klen;
	char *kp;

	if (!SvOK(k)) {
		if (ckWARN(WARN_UNINITIALIZED)) report_uninit();
		XSRETURN_NO;
	}
	this = (struct cdb *)SvPV(SvRV(db), PL_na);
	kp = SvPV(k, klen);
	RETVAL = cdb_find(this, kp, klen);
	if (RETVAL != 0 && RETVAL != 1) readerror();

	OUTPUT:
		RETVAL

void
cdb_DESTROY(db)
	SV *		db

	PROTOTYPE: $

	CODE:

	if (SvCUR(SvRV(db)) == sizeof(struct cdb)) { /* It came from TIEHASH. */
		struct cdb *this;
		IO *io;

		this = (struct cdb *)SvPV(SvRV(db), PL_na);
		iter_end(this);
#ifdef HASMMAP
		if (this->map) {
			munmap(this->map, this->size);
			this->map = 0;
		}
#endif
		io = GvIOn(this->glob);
		PerlIO_close(IoIFP(io)); /* close() on O_RDONLY cannot fail */
		IoIFP(io) = Nullfp;
		SvREFCNT_dec((SV *)this->glob);
	} else {
		struct cdb_make *this;

		this = (struct cdb_make *)SvPV(SvRV(db), PL_na);
		SvREFCNT_dec((SV *)this);
	}

SV *
cdb_FIRSTKEY(db)
	SV *		db

	PROTOTYPE: $

	CODE:
	struct cdb *this;
	char buf[8];
	U32 klen;

	this = (struct cdb *)SvPV(SvRV(db), PL_na);

	iter_start(this);
	if (iter_key(this))
		ST(0) = sv_mortalcopy(this->curkey);
	else
		XSRETURN_UNDEF; /* empty database */

SV *
cdb_NEXTKEY(db, k)
	SV *		db
	SV *		k

	PROTOTYPE: $$

	CODE:
	struct cdb *this;
	char buf[8], *kp;
	int found;
	off_t pos;
	U32 dlen, klen0;
	STRLEN klen1;

	if (!SvOK(k)) {
		if (ckWARN(WARN_UNINITIALIZED)) report_uninit();
		XSRETURN_UNDEF;
	}
	this = (struct cdb *)SvPV(SvRV(db), PL_na);
	if (this->end == 0 || !sv_eq(this->curkey, k))
		croak("Use CDB_File::FIRSTKEY before CDB_File::NEXTKEY");
	iter_advance(this);
	if (iter_key(this))
		ST(0) = sv_mortalcopy(this->curkey);
	else {
		iter_start(this);
		(void)iter_key(this); /* prepare curkey for FETCH */
		this->fetch_advance = 1;
		XSRETURN_UNDEF;
	}

SV *
cdb_new(this, fn, fntemp)
	char *		this
	char *		fn
	char *		fntemp

	PROTOTYPE: $$$

	CODE:
	SV *cdbmp;
	struct cdb_make cdbmake;
	int i;

	cdbmake.f = PerlIO_open(fntemp, "wb");
	if (!cdbmake.f) XSRETURN_UNDEF;

	if (cdb_make_start(&cdbmake) < 0) XSRETURN_UNDEF;

	/* Oh, for referential transparency. */
	New(0, cdbmake.fn, strlen(fn) + 1, char);
	New(0, cdbmake.fntemp, strlen(fntemp) + 1, char);
	strncpy(cdbmake.fn, fn, strlen(fn) + 1);
	strncpy(cdbmake.fntemp, fntemp, strlen(fntemp) + 1);

	cdbmp = newSVpv((char *)&cdbmake, sizeof(struct cdb_make));
	RETVAL = newRV_noinc(cdbmp);
	sv_bless(RETVAL, gv_stashpv(this, 0));

	OUTPUT:
		RETVAL

void
cdb_insert(cdbmake, k, v)
	SV *		cdbmake
	SV *		k
	SV *		v

	PROTOTYPE: $$$

	CODE:
	char *kp, *vp, packbuf[8];
	int c, i;
	STRLEN klen, vlen;
	struct cdb_make *this;
	U32 h;

	this = (struct cdb_make *)SvPV(SvRV(cdbmake), PL_na);
	kp = SvPV(k, klen); vp = SvPV(v, vlen);
	uint32_pack(packbuf, klen);
	uint32_pack(packbuf + 4, vlen);

	if (PerlIO_write(this->f, packbuf, 8) < 8) writeerror();

	h = cdb_hash(kp, klen);
	if (PerlIO_write(this->f, kp, klen) < klen) writeerror();
	if (PerlIO_write(this->f, vp, vlen) < vlen) writeerror();

	if (cdb_make_addend(this, klen, vlen, h) == -1) nomem();


int
cdb_finish(cdbmake)
	SV *		cdbmake;

	PROTOTYPE: $

	CODE:
	char buf[8];
	int i;
	struct cdb_make *this;
	U32 len, u;
	U32 count, memsize, where;
	struct cdb_hplist *x, *prev;
	struct cdb_hp *hp;

	this = (struct cdb_make *)SvPV(SvRV(cdbmake), PL_na);

	for (i = 0; i < 256; ++i)
		this->count[i] = 0;

	for (x = this->head; x; x = x->next) {
		i = x->num;
		while (i--)
			++this->count[255 & x->hp[i].h];
	}

	memsize = 1;
	for (i = 0; i < 256; ++i) {
		u = this->count[i] * 2;
		if (u > memsize)
			memsize = u;
	}

	memsize += this->numentries; /* no overflow possible up to now */
	u = (U32) 0 - (U32) 1;
	u /= sizeof(struct cdb_hp);
	if (memsize > u) { errno = ENOMEM; XSRETURN_UNDEF; }

	New(0xCDB, this->split, memsize, struct cdb_hp);

	this->hash = this->split + this->numentries;

	u = 0;
	for (i = 0; i < 256; ++i) {
		u += this->count[i]; /* bounded by numentries, so no overflow */
		this->start[i] = u;
	}

	prev = 0;
	for (x = this->head; x; x = x->next) {
		i = x->num;
		while (i--)
			this->split[--this->start[255 & x->hp[i].h]] = x->hp[i];
		if (prev) Safefree(prev);
		prev = x;
	}
	if (prev) Safefree(prev);

	for (i = 0; i < 256; ++i) {
		count = this->count[i];

		len = count + count; /* no overflow possible */
		uint32_pack(this->final + 8 * i, this->pos);
		uint32_pack(this->final + 8 * i + 4, len);

		for (u = 0; u < len; ++u)
			this->hash[u].h = this->hash[u].p = 0;

		hp = this->split + this->start[i];
		for (u = 0; u < count; ++u) {
			where = (hp->h >> 8) % len;
			while (this->hash[where].p)
				if (++where == len)
					where = 0;
			this->hash[where] = *hp++;
		}

		for (u = 0; u < len; ++u) {
			uint32_pack(buf, this->hash[u].h);
			uint32_pack(buf + 4, this->hash[u].p);
			if (PerlIO_write(this->f, buf, 8) == -1) XSRETURN_UNDEF;
			if (posplus(this, 8) == -1) XSRETURN_UNDEF;
		}
	}

	Safefree(this->split);

	if (PerlIO_flush(this->f) == EOF) writeerror();
	PerlIO_rewind(this->f);

	if (PerlIO_write(this->f, this->final, sizeof this->final) < sizeof this->final) writeerror();
	if (PerlIO_flush(this->f) == EOF) writeerror();

	if (fsync(PerlIO_fileno(this->f)) == -1) XSRETURN_NO;
	if (PerlIO_close(this->f) == EOF) XSRETURN_NO;

	if (rename(this->fntemp, this->fn)) XSRETURN_NO;
	
	Safefree(this->fn);
	Safefree(this->fntemp);

	RETVAL = 1;

	OUTPUT:
		RETVAL
