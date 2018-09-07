# -*- coding: utf-8 -*-  

import numpy as np  
import argparse
import matplotlib.pyplot as plt  

Time_precision = "s"

def plotfig(y_dict):
    plt.figure(figsize=(12,8)) #创建绘图对象

    y_max = 0
    t_max = 0

    for key in sorted(y_dict.keys()):
        y = y_dict[key]
        time = []
        tp = []
        avg_tp = 0
        avg_times = 0
        for t_key in sorted(y):
            if Time_precision == "ms":
                time.append(float(t_key)/1000)
            elif Time_precision == "s":
                time.append(float(t_key)/1000000)
            tp.append(y[t_key])
        if max(tp) > y_max:
            y_max = max(tp)
        plt.plot(time,tp,label=key,linewidth=1.5)   #在当前绘图对象绘图（X轴，Y轴，蓝色虚线，线宽度） 

    plt.xticks(fontsize=40)
    plt.yticks(fontsize=40)
    if Time_precision == "ms":
        plt.xlabel("Time (ms)", fontsize=40) #X轴标签  
    elif Time_precision == "s":
        plt.xlabel("Time (s)", fontsize=40) #X轴标签  
    plt.ylabel("RDMA Throughput (Gbps)", fontsize=40)  #Y轴标签  
    #plt.title("RDMA Throughput") #图标题       
    plt.xlim(xmin=0)  #x轴的范围 
    plt.ylim(0,y_max*1.1)  #x轴的范围 
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
    parser.add_argument('-f', '--file', type=str, default="/home/shuai/throughput/sq.txt")
    args = parser.parse_args()
    tracefile = args.file

    rx_bytes = {}
    throughput = {}
    start_time = 0
    rx_bytes_start_time = 0
    rx_bytes_end_time = 0
    interval = 1000000  # interval (in microsecond): 1000 us = 1 ms
    interval_old_time = 0
    unit = "Gbps"
    last_time = 0

    with open(tracefile) as tracef:
        line = tracef.readline() # skip the first line
        line = tracef.readline()
        rx_bytes_start_time = int(line.split()[0])
        interval_old_time = 0
        while 1:
            if not line :
                break;
            else:
                line = line.split()
                if len(line) < 3:
                    line = tracef.readline()
                    continue; # incomplete line

                time = int(line[0]) - rx_bytes_start_time # convert absolute time to relative time
                rx_bytes_end_time = time

                '''print("%f \t\t %d" % (float(time - last_time)/1000, int(line[2])))
                last_time = time'''

                if (time - interval_old_time >= interval):
                    for key in rx_bytes:
                        if key not in throughput:
                            throughput[key] = {}

                        tp = rx_bytes[key] * 8 / (time - interval_old_time)
                        if unit == "Gbps":
                            tp = tp / 1000                       
                        elif unit == "MGbps":
                            tp = tp

                        throughput[key][time] = tp
                        rx_bytes[key] = 0

                    interval_old_time = time

                key = line[1]
                if key not in rx_bytes:
                    rx_bytes[key] = 0
                else:
                    rx_bytes[key] = rx_bytes[key] + int(line[2])

            line = tracef.readline()

    plotfig(throughput)

if __name__ == '__main__':
    main()