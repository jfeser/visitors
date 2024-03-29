# -------------------------------------------------------------------------

# This Makefile is not distributed.

SHELL := bash
export CDPATH=

.PHONY: package check export tag opam pin unpin versions

# -------------------------------------------------------------------------

include Makefile

# -------------------------------------------------------------------------

# Utilities.

MD5SUM  := $(shell if command -v md5 >/dev/null 2>/dev/null ; \
                   then echo "md5 -r" ; else echo md5sum ; fi)

# -------------------------------------------------------------------------

# Distribution.

# The version number is automatically set to the current date,
# unless DATE is defined on the command line.
DATE     := $(shell /bin/date +%Y%m%d)

PACKAGE  := visitors-$(DATE)
CURRENT  := $(shell pwd)
TARBALL  := $(CURRENT)/$(PACKAGE).tar.gz

# -------------------------------------------------------------------------

# A list of files to copy without changes to the package.
#
# This does not include the src/ and doc/ directories, which require
# special treatment.

DISTRIBUTED_FILES := AUTHORS CHANGES.md LICENSE Makefile

# -------------------------------------------------------------------------

# Creating a tarball for distribution.

package:
# Make sure the correct version is installed.
	@ make -C src reinstall
# Create a directory to store the distributed files temporarily.
	@ rm -rf $(PACKAGE)
	@ mkdir -p $(PACKAGE)/src
	@ cp $(DISTRIBUTED_FILES) $(PACKAGE)
	@ cp src/*.ml{,i,lib} src/Makefile src/Makefile.preprocess src/META src/_tags $(PACKAGE)/src
# Set the version number into the files that mention it.
# These include version.tex, META.
	@ echo "Setting version to $(DATE)."
	@ echo version = \"$(DATE)\" >> $(PACKAGE)/src/META
# Copy and compile the documentation.
# This requires %.processed.ml files in the test/ directory,
# which in turn requires building (and installing) in src/.
	@ echo "Generating the documentation."
	@ cp -r doc test $(PACKAGE)
	@ make -C $(PACKAGE)/test clean processed
	@ echo '\gdef\visitorsversion{$(DATE)}' > $(PACKAGE)/doc/version.tex
	@ make -C $(PACKAGE)/doc clean all
	@ mv $(PACKAGE)/doc/main.pdf $(PACKAGE)/manual.pdf
	@ rm -rf $(PACKAGE)/doc $(PACKAGE)/test
	@ make -C $(PACKAGE)/src clean
# Create the tarball.
	@ echo "Creating a tarball."
	tar --exclude-from=.gitignore -cvz -f $(TARBALL) $(PACKAGE)
	@ echo "The package $(PACKAGE).tar.gz is ready."

# -------------------------------------------------------------------------

# Checking the tarball that was created above.

check:
	@ echo "Checking the package ..."
# Create a temporary directory; extract, build, and install.
	@ TEMPDIR=`mktemp -d /tmp/visitors-test.XXXXXX` && { \
	echo "   * Extracting. " && \
	(cd $$TEMPDIR && tar xfz $(TARBALL)) && \
	echo "   * Compiling and installing." && \
	(cd $$TEMPDIR/$(PACKAGE) && make reinstall \
	) > $$TEMPDIR/install.log 2>&1 \
		|| (cat $$TEMPDIR/install.log; exit 1) && \
	echo "   * Uninstalling." && \
	(cd $$TEMPDIR/$(PACKAGE) && make uninstall \
	) > $$TEMPDIR/uninstall.log 2>&1 \
		|| (cat $$TEMPDIR/uninstall.log; exit 1) && \
	rm -rf $$TEMPDIR ; }
	@ echo "The package $(PACKAGE) seems ready for distribution!"

# -------------------------------------------------------------------------

# Copying the tarball to my Web site.

RSYNC   := scp -p -C
TARGET  := yquem.inria.fr:public_html/visitors/

export:
# Copier l'archive et la doc vers yquem.
	$(RSYNC) $(TARBALL) $(TARGET)
	$(RSYNC) $(PACKAGE)/manual.pdf $(TARGET)

# -------------------------------------------------------------------------

# Creating a git tag.

tag:
	git tag -a $(DATE) -m "Release $(DATE)."

# -------------------------------------------------------------------------

# Updating the opam package.

# This entry assumes that "make package" and "make export" have been
# run on the same day.

CSUM  = $(shell $(MD5SUM) visitors-$(DATE).tar.gz | cut -d ' ' -f 1)

opam:
	echo "This GNUmakefile entry needs to be updated to use opam publish."

# -------------------------------------------------------------------------

# Pinning.

pin:
	opam pin add visitors `pwd` -k git

unpin:
	opam pin remove visitors

# -------------------------------------------------------------------------

# Trying out compilation under multiple versions of OCaml.

# TEMPORARY (ppx_import currently unavailable on 4.08)

versions:
	for i in 4.02.3 4.03.0 4.04.0 4.05.0 4.06.0 4.07.0 4.08.0 ; do \
	  opam switch $$i && eval `opam config env` && ocamlc -v && \
	  opam install hashcons ppx_deriving ocp-indent && \
	  make clean && \
	  make && \
	  make reinstall ; \
	done
