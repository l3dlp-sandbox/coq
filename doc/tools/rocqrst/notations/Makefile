##########################################################################
##         #      The Rocq Prover / The Rocq Development Team           ##
##  v      #         Copyright INRIA, CNRS and contributors             ##
## <O___,, # (see version control and CREDITS file for authors & dates) ##
##   \VV/  ###############################################################
##    //   #    This file is distributed under the terms of the         ##
##         #     GNU Lesser General Public License Version 2.1          ##
##         #     (see LICENSE file for the text of the license)         ##
##########################################################################
# Parsing compact tactic notation syntax in

TEST_INPUT="unfold {+, @qualid|@string at {+, num}}"

python:
	antlr4 -Dlanguage=Python3 -visitor -no-listener TacticNotations.g

java:
	antlr4 -Dlanguage=Java TacticNotations.g && javac TacticNotations*.java

test: java
	grun TacticNotations top -tree <<< "$(TEST_INPUT)"

gui: java
	grun TacticNotations top -gui <<< "$(TEST_INPUT)"

sample:
	cd ..; python3 -m rocqnotations.driver < ../tests/tactics > ../tests/antlr-notations.html
