################################################################################
# Sketch
#

SRCSUFFIXES = *.cpp *.c *.S

MAKE_INC=$(wildcard $(SRCROOT)/make.inc)

# Sketch source files
SKETCHPDESRCS  := $(wildcard $(SRCROOT)/*.pde $(SRCROOT)/*.ino)
SKETCHSRCS     := $(wildcard $(addprefix $(SRCROOT)/,$(SRCSUFFIXES)))
SKETCHPDE      := $(wildcard $(SRCROOT)/$(SKETCH).pde $(SRCROOT)/$(SKETCH).ino)
ifeq (,$(MAKE_INC))
 SKETCHCPP      := $(BUILDROOT)/$(SKETCH).cpp
 ifneq ($(words $(SKETCHPDE)),1)
  $(error ERROR: sketch $(SKETCH) must contain exactly one of $(SKETCH).pde or $(SKETCH).ino)
 endif
else
 SKETCHCPP      := $(SRCROOT)/$(SKETCH).cpp
endif

# Sketch object files
SKETCHOBJS := $(subst $(SRCROOT),$(BUILDROOT),$(SKETCHSRCS))
ifeq (,$(MAKE_INC))
 SKETCHOBJS += $(SKETCHCPP)
endif
SKETCHOBJS := $(addsuffix .o,$(basename $(SKETCHOBJS)))

# List of input files to the sketch.cpp file in the order they should
# be appended to create it
SKETCHCPP_SRC := $(SKETCHPDE) $(sort $(filter-out $(SKETCHPDE),$(SKETCHPDESRCS)))

################################################################################
# Libraries
#
# Pick libraries to add to the include path and to link with based on
# #include directives in the sketchfiles.
#
# For example:
#
#   #include <Foo.h>
#
# implies that there might be a Foo library.
#
# Note that the # and $ require special treatment to avoid upsetting
# make.
#
SEXPR = 's/^[[:space:]]*\#include[[:space:]][<\"]([^>\"./]+).*$$/\1/p'
ifneq (,$(MAKE_INC))
 include $(MAKE_INC)
 LIBTOKENS := $(LIBRARIES)
else
ifeq ($(SYSTYPE),Darwin)
  LIBTOKENS        :=    $(sort $(shell cat $(SKETCHPDESRCS) $(SKETCHSRCS) | sed -nEe $(SEXPR)))
else
  LIBTOKENS        :=    $(sort $(shell cat $(SKETCHPDESRCS) $(SKETCHSRCS) | sed -nre $(SEXPR)))
endif
endif

#
# Find sketchbook libraries referenced by the sketch.
#
# Include paths for sketch libraries 
#
SKETCHLIBS		:=	$(wildcard $(addprefix $(SKETCHBOOK)/libraries/,$(LIBTOKENS)))
SKETCHLIBNAMES		:=	$(notdir $(SKETCHLIBS))
SKETCHLIBSRCDIRS	:=	$(SKETCHLIBS) $(addsuffix /utility,$(SKETCHLIBS))
SKETCHLIBSRCS		:=	$(wildcard $(foreach suffix,$(SRCSUFFIXES),$(addsuffix /$(suffix),$(SKETCHLIBSRCDIRS))))
SKETCHLIBOBJS		:=	$(addsuffix .o,$(basename $(subst $(SKETCHBOOK),$(BUILDROOT),$(SKETCHLIBSRCS))))
SKETCHLIBINCLUDES	:=	$(addprefix -I,$(SRCROOT))
SKETCHLIBINCLUDES	+=	$(addprefix -I,$(SKETCHLIBS))
SKETCHLIBSRCSRELATIVE	:=	$(subst $(SKETCHBOOK)/,,$(SKETCHLIBSRCS))

ifeq ($(VERBOSE),)
v = @
else
v =
endif

.PHONY: $(BUILDROOT)/make.flags
$(BUILDROOT)/make.flags:
	@mkdir -p $(BUILDROOT)
	@echo "// BUILDROOT=$(BUILDROOT) HAL_BOARD=$(HAL_BOARD) HAL_BOARD_SUBTYPE=$(HAL_BOARD_SUBTYPE) TOOLCHAIN=$(TOOLCHAIN) EXTRAFLAGS=$(EXTRAFLAGS)" > $(BUILDROOT)/make.flags
	@cat $(BUILDROOT)/make.flags


ifeq (,$(MAKE_INC))
# Build the sketch.cpp file
$(SKETCHCPP): $(BUILDROOT)/make.flags $(SKETCHCPP_SRC)
	@echo "building $(SKETCHCPP)"
	$(RULEHDR)
	$(v)cat $(BUILDROOT)/make.flags > $@.new
	$(v)$(AWK) -v mode=header '$(SKETCH_SPLITTER)'   $(SKETCHCPP_SRC) >> $@.new
	$(v)echo "#line 1 \"autogenerated\""                              >> $@.new
	$(v)$(AWK)                '$(SKETCH_PROTOTYPER)' $(SKETCHCPP_SRC) >> $@.new
	$(v)$(AWK) -v mode=body   '$(SKETCH_SPLITTER)'   $(SKETCHCPP_SRC) >> $@.new
	$(v)cmp $@ $@.new > /dev/null 2>&1 || mv $@.new $@
	$(v)rm -f $@.new

# delete the sketch.cpp file if a processing error occurs
.DELETE_ON_ERROR: $(SKETCHCPP)
endif

#
# The sketch splitter is an awk script used to split off the
# header and body of the concatenated .pde/.ino files.  It also
# inserts #line directives to help in backtracking from compiler
# and debugger messages to the original source file.
#
# Note that # and $ require special treatment here to avoid upsetting
# make.
#
# This script requires BWK or GNU awk.
#
define SKETCH_SPLITTER
  BEGIN { 							\
    scanning = 1; 						\
    printing = (mode ~ "header") ? 1 : 0;			\
  }								\
  { toggles = 1 }						\
  (FNR == 1) && printing { 					\
    printf "#line %d \"%s\"\n", FNR, FILENAME;			\
  }								\
  /^[[:space:]]*\/\*/,/\*\// { 					\
    toggles = 0;						\
  }								\
  /^[[:space:]]*$$/ || /^[[:space:]]*\/\/.*/ || /^\#.*$$/ { 	\
    toggles = 0;						\
  }								\
  scanning && toggles { 					\
    scanning = 0; 						\
    printing = !printing;					\
    if (printing) { 						\
      printf "#line %d \"%s\"\n", FNR, FILENAME;		\
    }								\
  }								\
  printing
endef

#
# The prototype scanner is an awk script used to generate function
# prototypes from the concantenated .pde/.ino files.
#
# Function definitions are expected to follow the form
#
#   <newline><type>[<qualifier>...]<name>([<arguments>]){
#
# with whitespace permitted between the various elements.  The pattern
# is assembled from separate subpatterns to make adjustments easier.
#
# Note that $ requires special treatment here to avoid upsetting make,
# and backslashes are doubled in the partial patterns to satisfy
# escaping rules.
#
# This script requires BWK or GNU awk.
#
define SKETCH_PROTOTYPER
  BEGIN {								\
    RS="{";								\
    type       = "((\\n)|(^))[[:space:]]*[[:alnum:]_]+[[:space:]]+";	\
    qualifiers = "([[:alnum:]_\\*&]+[[:space:]]*)*";			\
    name       = "[[:alnum:]_]+[[:space:]]*";				\
    args       = "\\([[:space:][:alnum:]_,&\\*\\[\\]]*\\)";		\
    bodycuddle = "[[:space:]]*$$";					\
    pattern    = type qualifiers name args bodycuddle;			\
  }									\
  match($$0, pattern) {							\
    proto = substr($$0, RSTART, RLENGTH);				\
    gsub("\n", " ", proto);						\
    printf "%s;\n", proto;						\
  }
endef

# common header for rules, prints what is being built
define RULEHDR
	@echo %% $(subst $(BUILDROOT)/,,$@)
	@mkdir -p $(dir $@)
endef
