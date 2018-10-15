# -*- coding: utf-8 -*-  
from __future__ import print_function

import numpy as np  
import argparse
import matplotlib.pyplot as plt 
import socket
import linecache
from openpyxl import Workbook

Time_precision = "s"

def plotfig(y_dict, axis_min, axis_max, axis_high):
    plt.figure(figsize=(12,8)) #创建绘图对象

    y_max = 0
    t_max = 0
    time = []
    tp = []

    for t_key in sorted(y_dict.keys()):
        if Time_precision == "ms":
            time.append(float(t_key)/1000000)
        elif Time_precision == "s":
            time.append(float(t_key)/1000000000)
        tp.append(y_dict[t_key])
    if max(tp) > y_max:
        y_max = max(tp)
    plt.plot(time,tp,linewidth=1.5)   #在当前绘图对象绘图（X轴，Y轴，蓝色虚线，线宽度） 

    plt.xticks(fontsize=40)
    plt.yticks(fontsize=40)
    if Time_precision == "ms":
        plt.xlabel("Time (ms)", fontsize=40) #X轴标签  
    elif Time_precision == "s":
        plt.xlabel("Time (s)", fontsize=40) #X轴标签  
    plt.ylabel("RDMA Throughput (Gbps)", fontsize=40)  #Y轴标签  
    #plt.title("RDMA Throughput") #图标题
    if axis_max :       
        plt.xlim(xmin=axis_min, xmax=axis_max)  #x轴的范围 
    else :
        plt.xlim(xmin=axis_min)
    if not axis_high :
        plt.ylim(0,y_max*1.1)  #y轴的范围 
    else :
        plt.ylim(0,axis_high)  #y轴的范围 
    ax = plt.gca()
    ax.spines['right'].set_visible(False)
    ax.spines['top'].set_visible(False) 
    '''if PRINT_LEGEND == 1:
        sum_legend = plt.legend(handles=[sum_fig], loc=1, frameon=False)
        ax.add_artist(sum_legend)'''
    #plt.legend(loc='lower left') #显示图例 'best', 'upper right', 'upper left', 'lower left', 'lower right', 'center'       
    plt.show()  #显示图  
    #plt.savefig("Throughput.jpg") #保存图

def main():
    parser = argparse.ArgumentParser(description="progrom description")
    parser.add_argument('-f', '--file', type=str, default="0.log")
    parser.add_argument('-o', '--outputfile', type=str, default="modified_0.log")
    parser.add_argument('-x', '--xlsxfile', type=str, default="0.xlsx")
    parser.add_argument('-i', '--interval', type=int, default=1)
    parser.add_argument('-l', '--min', type=float, default=0)
    parser.add_argument('-r', '--max', type=float)
    parser.add_argument('-hi', '--high', type=float)
    args = parser.parse_args()
    tracefile = args.file
    interval = args.interval
    outputfile = args.outputfile
    xlsxfile = args.xlsxfile
    axis_min = args.min
    axis_max = args.max
    axis_high = args.high

    acc_byte = {}
    throughput = {}
    interval = 1000 * 1000 * interval  # interval (in nanosecond): 1000000 us = 1 ms
    unit = "Gbps"
    byte = 0
    index = 0
    total_intervals = 0
    line_cur = 3
    last_end_time = 0
    next_start_time = 0
    broken_line_byte = [0 for i in xrange(1000)] # assuming that at most 1000 continuous lines are broken
    period = [0 for i in xrange(1000)]
    all_broken_line_bytes = 0
    is_end = 0

    outputf = open(outputfile, "w")
    print(" start time (ns)    end time (ns)         sqe index   length (Bytes)  is_modified", file=outputf)
    time_0 = int(linecache.getline(tracefile, 1))
    line = linecache.getline(tracefile, line_cur) # skip the first two line
    while 1 :
        if not line:
            break
        line = line.split()
        if len(line) < 4 :
            break
        
        if int(line[0]) == 0 and int(line[1]) == 0:
            distance = 1

            broken_line_byte[0] = socket.ntohl(int(line[3]))
            all_broken_line_bytes = broken_line_byte[0]
            unbroken_line = linecache.getline(tracefile, line_cur + distance)
            while int(unbroken_line.split()[0]) == 0 :
                broken_line_byte[distance] = socket.ntohl(int(unbroken_line.split()[3]))
                all_broken_line_bytes = all_broken_line_bytes + broken_line_byte[distance]
                distance = distance + 1
                unbroken_line = linecache.getline(tracefile, line_cur + distance)
                if not unbroken_line:
                    is_end = 1
                    break

            if is_end == 1 :
                break
            next_start_time = int(unbroken_line.split()[0])

            for i in xrange(distance) :
                modifing_line = linecache.getline(tracefile, line_cur + i)
                modifing_line = modifing_line.split()
                period[i] = int(float(next_start_time - last_end_time) * broken_line_byte[i] / all_broken_line_bytes)
                left_time = 0
                right_time = period[0]
                for ii in xrange(i) :
                    left_time = left_time + period[ii]
                    right_time = right_time + period[ii + 1] 

                modifing_line[0] = str(last_end_time + left_time - time_0)
                modifing_line[1] = str(last_end_time + right_time - time_0)

                byte = socket.ntohl(int(modifing_line[3]))
                print("%16s  %16s %16s %16d   1" % (modifing_line[0], modifing_line[1], modifing_line[2], 0 if byte == 2147483648 else byte), file=outputf)

            line_cur = line_cur + distance - 1
        else :
            last_end_time = int(line[1])
            byte = socket.ntohl(int(line[3]))
            line[0] = str(int(line[0]) - time_0)
            line[1] = str(int(line[1]) - time_0)
            print("%16s  %16s %16s %16d" % (line[0], line[1], line[2], 0 if byte == 2147483648 else byte), file=outputf)

        line_cur = line_cur + 1
        line = linecache.getline(tracefile, line_cur)

    outputf.close()


    with open(outputfile) as tracef:
        line = tracef.readline() # skip the first line

        line = tracef.readline()
        while 1 :
            if not line:
                break
            line = line.split()
            if len(line) < 4 :
                break

            start_time = int(line[0])
            end_time = int(line[1])
            left_cur = start_time / interval
            right_cur = end_time / interval
            interval_num = right_cur - left_cur + 1

            if interval_num == 1 :
                byte = int(line[3])

                index = left_cur * interval + interval / 2
                if index not in acc_byte :
                    acc_byte[index] = byte
                else :
                    acc_byte[index] = acc_byte[index] + byte
            else :               
                for i in xrange(interval_num) :
                    if i !=0 and i != (interval_num - 1) :
                        byte = int(float(line[3]) * interval / (end_time - start_time))
                    elif i == 0 :
                        byte = int(float(line[3]) * ((left_cur + 1) * interval - start_time) / (end_time - start_time))
                    elif i == (interval_num - 1) :
                        byte = int(float(line[3]) * (end_time - right_cur * interval) / (end_time - start_time))

                    index = (left_cur + i) * interval + interval / 2
                    if index not in acc_byte :
                        acc_byte[index] = byte
                    else :
                        acc_byte[index] = acc_byte[index] + byte

            line = tracef.readline()  
    
    total_intervals = index / interval + 1
    for idx in xrange(total_intervals) :
        index = idx * interval + interval / 2
        if index not in acc_byte :
            throughput[index] = 0
        else :
            tp = float(acc_byte[index]) / interval * 8
            if unit == "Gbps" :
                throughput[index] = tp
            elif unit == "Mbps" :
                throughput[index] = tp * 1000

    wb = Workbook()
    sheet = wb.active
    sheet["A1"].value = "time/ms"
    sheet["B1"].value = "throughput/Gbps"
    i = 0
    for time in sorted(throughput.keys()):
        sheet["A"+str(i+2)].value = time/1000000.0
        sheet["B"+str(i+2)].value = throughput[time]
        i = i + 1
    wb.save(xlsxfile)

    plotfig(throughput, axis_min, axis_max, axis_high)

if __name__ == '__main__':
    main()