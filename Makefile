OBJCC ?= clang
AR ?= ar
CFLAGS ?= -O2

PREFIX ?= /usr
LIBDIR ?= $(PREFIX)/lib

SOBASE = libarclite.so
SONAME = $(SOBASE).1
SHAREDLIB = $(SONAME).69.0
STATICLIB = libarclite.a

EXTRA_CFLAGS = -std=c99 -Wall -Wextra -fPIC
LDFLAGS = -framework CoreFoundation -framework Foundation -lobjc -lsystem_blocks -ldispatch

OBJS = ARC.o

all: $(SHAREDLIB) $(STATICLIB)

.m.o:
	$(OBJCC) $(EXTRA_CFLAGS) $(CFLAGS) -c -o $@ $<

$(SHAREDLIB): $(OBJS)
	$(OBJCC) $(OBJS) $(EXTRA_CFLAGS) $(CFLAGS) $(LDFLAGS) \
		-nolibc -shared  -o $(SHAREDLIB)

$(STATICLIB): $(OBJS)
	$(AR) -rcs $(STATICLIB) $(OBJS)

# no tests
check:
	:

clean:
	rm -f $(OBJS) $(SHAREDLIB) $(STATICLIB)

install: $(SHAREDLIB) $(STATICLIB)
	install -d $(DESTDIR)$(LIBDIR)
	install -m 755 $(SHAREDLIB) $(DESTDIR)$(LIBDIR)
	install -m 755 $(STATICLIB) $(DESTDIR)$(LIBDIR)
	ln -sf $(SHAREDLIB) $(DESTDIR)$(LIBDIR)/$(SOBASE)
	ln -sf $(SHAREDLIB) $(DESTDIR)$(LIBDIR)/$(SONAME)
