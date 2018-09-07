#!/bin/bash
for x in `ls *.tar.gz`
do
	tar zxvf $x
done
