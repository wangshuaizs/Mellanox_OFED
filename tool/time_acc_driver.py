# -*- coding: utf-8 -*-  
from __future__ import print_function

import numpy as np  
import argparse
from openpyxl import Workbook


def main():
    parser = argparse.ArgumentParser(description="progrom description")
    parser.add_argument('-f', '--file', type=str, default="time_acc.txt")
    parser.add_argument('-x', '--xlsxfile', type=str, default="time_acc.xlsx")
    args = parser.parse_args()
    tracefile = args.file
    xlsxfile = args.xlsxfile

    last_time = 0

    wb = Workbook()
    sheet = wb.active
    sheet["A1"].value = "time (ms)"
    sheet["B1"].value = "tensor size (bytes)"
    i = 0
    with open(tracefile) as tracef:
        line = tracef.readline()
        last_time = int(line.split()[0])
        while 1 :
            if not line:
                break
            line = line.split()
            if len(line) < 4 :
                break

            time = int(line[0])
            if int(line[3]) != 0 and int(line[3]) != 583:
                sheet["A"+str(i+2)].value = (time - last_time) / 1000000.0
                sheet["B"+str(i+2)].value = int(line[3])
                i = i + 1

            #last_time = time
            line = tracef.readline()
        
    wb.save(xlsxfile)

if __name__ == '__main__':
    main()