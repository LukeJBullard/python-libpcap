# -*- coding: utf-8 -*-
# @Author: JanKinCai
# @Date:   2019-09-10 12:53:07
# @Last Modified by:   jankincai
# @Last Modified time: 2021-01-28 22:19:29
import os
import time
from threading import BoundedSemaphore, Event
from pylibpcap.KillableThread import KillableThread

from pylibpcap.utils import to_c_str, from_c_str, get_pcap_file
from pylibpcap.exception import LibpcapError


DEF BUFSIZ = 65535
DEF PCAP_VERSION_MAJOR = 2
DEF PCAP_VERSION_MINOR = 4
DEF PCAP_ERRBUF_SIZE = 256
DEF PCAP_IF_LOOPBACK = 0x00000001
DEF MODE_CAPT = 0
DEF MODE_STAT = 1

DEF PCAP_ERROR = -1
DEF PCAP_ERROR_BREAK = -2
DEF PCAP_ERROR_NOT_ACTIVATED = -3
DEF PCAP_ERROR_ACTIVATED = -4
DEF PCAP_ERROR_NO_SUCH_DEVICE = -5

cdef class BasePcap(object):
    """BasePcap

    :param path: Input file
    :param filters: BPF Filters, default ``""``
    :param mode: open model, default ``r``
    :param snaplen: Cut packet lenght, default ``65535``
    """

    def __init__(self, str path, mode="r", str filters="", int snaplen=65535, *args, **kwargs):
        """
        init
        """

        self.path = os.path.expanduser(self._to_c_str(path))
        self.filters = self._to_c_str(filters)
        self.snaplen = snaplen
        self.mode = mode

        self.in_pcap = pcap_open_offline(self.path, self.errbuf) if mode == "r" else NULL
        self.out_in_pcap = pcap_open_offline(self.path, self.errbuf) if mode == "a" and os.path.exists(path) else NULL
        self.out_pcap = pcap_dump_open(pcap_open_dead(1, self.snaplen), self.path) if mode == "a" or mode == "w" else NULL

        if mode == "a" and self.out_in_pcap != NULL:
            self.pcap_next_dump(self.out_in_pcap, "")

    def _to_c_str(self, v):
        """Python str to C str
        """

        return to_c_str(v)

    def _from_c_str(self, v):
        """C str to Python str
        """

        return from_c_str(v)

    def get_errbuf(self):
        """Get errbuf
        """

        return self._from_c_str(self.errbuf)

    @property
    def isr(self):
        """Is Read
        """

        return self.mode == "r"

    @property
    def isw(self):
        """
        Is Write
        """

        return self.mode == "a" or self.mode == "w"

    cdef void set_filter(self, pcap_t* p, char* filters):
        """
        Set BPF Filter
        """

        cdef bpf_program fp

        if pcap_compile(p, &fp, filters, 1, 0) == -1:
            raise LibpcapError("compile bpf_filter error.")
        if pcap_setfilter(p, &fp) == -1:
            raise LibpcapError("set bpf_filter error.")
        pcap_freecode(&fp)

    cdef void pcap_write_dump(self, pcap_pkthdr pkt_header, bytes buf):
        """
        pcap write dump

        :param pkt_header: pcap_pkthdr struct.
        :param buf: bytes.
        """

        pkt_header.caplen = len(buf)
        pkt_header.len = pkt_header.caplen
        pkt_header.ts.tv_sec = int(time.time());
        pcap_dump(<u_char*>self.out_pcap, &pkt_header, buf)

    cdef void pcap_next_dump(self, pcap_t* in_pcap, char* filters):
        """
        pcap next dump
        """

        cdef u_char* pkt
        cdef pcap_pkthdr pkt_header

        if filters:
            self.set_filter(in_pcap, filters)

        while 1:
            pkt = <u_char*>pcap_next(in_pcap, &pkt_header)

            if pkt == NULL:
                break

            pcap_dump(<u_char*>self.out_pcap, &pkt_header, pkt)

    cdef void pcap_next_dumps(self, str path):
        """
        pcap_next_dumps
        """

        cdef pcap_t* in_pcap = NULL

        for f in get_pcap_file(path):
            in_pcap = pcap_open_offline(self._to_c_str(f), self.errbuf)

            if in_pcap == NULL:
                raise LibpcapError(self.get_errbuf())

            self.pcap_next_dump(in_pcap, self.filters)
            pcap_close(in_pcap)

    def close(self):
        """
        close
        """

        if self.out_pcap:
            pcap_dump_flush(self.out_pcap)
            pcap_dump_close(self.out_pcap)
            self.out_pcap = NULL

        if self.in_pcap:
            pcap_close(self.in_pcap)
            self.in_pcap = NULL

        if self.out_in_pcap:
            pcap_close(self.out_in_pcap)
            self.out_in_pcap = NULL

    def __dealloc__(self):
        """
        free memory
        """

        self.close()


cdef class LibPcap(BasePcap):
    """
    Pcap
    """

    def write(self, v):
        """
        Write pcap
        """

        cdef pcap_pkthdr pkt_header

        if not self.isw:
            raise LibpcapError("Not write.")

        if isinstance(v, bytes):
            self.pcap_write_dump(pkt_header, v)
        else:
            for buf in v:
                if isinstance(buf, bytes):
                    self.pcap_write_dump(pkt_header, buf)

    def read(self):
        """
        Read pcap
        """

        cdef pcap_pkthdr pkt_header

        cdef u_char *pkt

        if not self.isr:
            raise LibpcapError("Not Read.")

        if self.filters:
            self.set_filter(self.in_pcap, self.filters)

        while 1:

            pkt = <u_char*>pcap_next(self.in_pcap, &pkt_header)

            if pkt == NULL:
                break

            yield pkt_header.caplen, pkt_header.ts.tv_sec, (<char *>pkt)[:pkt_header.caplen]

    def write_path(self, path):
        """
        Write path
        """

        return self.pcap_next_dumps(path)


class StatsObject(object):
    def __init__(self, capture_cnt, ps_recv, ps_drop, ps_ifdrop):
        self.capture_cnt = capture_cnt
        self.ps_recv = ps_recv
        self.ps_drop = ps_drop
        self.ps_ifdrop = ps_ifdrop


cdef class Sniff(BasePcap):
    """
    Capture packet

    :param iface: Iface
    :param count: Capture packet num, default ``-1``
    :param promisc: Promiscuous mode, default ``0``
    :param snaplen: Cut packet lenght, default ``65535``
    :param timeout: capture timeout, default ``0``
    :param filters: BPF filter rules, default ``""``
    :param out_file: Output pcap file, default ``""``
    """

    cdef int threaded
    cdef object thread
    cdef object done_capturing
    cdef object capturing_threaded_requested
    cdef bint capturing_threaded
    cdef int promisc
    cdef int timeout
    cdef int immediate

    def __init__(self, str iface, int count=-1, int promisc=0, int snaplen=65535,
                 int timeout=0, immediate=0, str filters="", str out_file="", int monitor=-1, int threaded=0, *args, **kwargs):
        """init
        """

        self.out_file = os.path.expanduser(self._to_c_str(out_file))
        self.filters = self._to_c_str(filters)
        self.iface = self._to_c_str(iface)
        self.count = count
        self.handler = pcap_create(self.iface, self.errbuf)
        self.capture_cnt = 0
        self.threaded = threaded

        #threading events for waiting/interthread comm
        if self.threaded:
            self.done_capturing = Event()
            self.capturing_threaded_requested = Event()
        self.capturing_threaded = False

        self.snaplen=snaplen
        self.promisc=promisc
        self.timeout=timeout
        self.immediate=immediate

        # self.handler = pcap_open_live(self.iface, snaplen, promisc, 0, self.errbuf)

        pcap_set_snaplen(self.handler, self.snaplen)
        pcap_set_promisc(self.handler, self.promisc)
        pcap_set_timeout(self.handler, self.timeout)
        pcap_set_immediate_mode(self.handler, self.immediate)

        #check and set monitor mode if available
        if monitor > 0:
            rfmon_available = pcap_can_set_rfmon(self.handler)

            if rfmon_available == 1:
                #monitor mode can be set, set it now
                rfmon_set = pcap_set_rfmon(self.handler, 1)
                if rfmon_set == PCAP_ERROR_ACTIVATED:
                    raise LibpcapError("Monitor Mode Unavailable, capture handle already activated")
                elif rfmon_set != 0:
                    raise LibpcapError("Monitor Mode Unavailable, A Unknown Error has occurred")

            #see pcap_can_set_rfmon(3) Man Page
            elif rfmon_available == 0:
                raise LibpcapError("Monitor Mode unavailable")
            elif rfmon_available == PCAP_ERROR_NO_SUCH_DEVICE:
                raise LibpcapError("Monitor Mode Is unavailable, Device specified when handle created does not exist. [PCAP_ERROR_NO_SUCH_DEVICE]")
            elif rfmon_available == PCAP_ERROR_ACTIVATED:
                raise LibpcapError("Error enabling Monitor Mode, capture handle already activated")
            elif rfmon_available == PCAP_ERROR:
                raise LibpcapError(self.get_handler_error())

        if pcap_activate(self.handler) != 0:
            raise LibpcapError(self.get_handler_error())

        # Set BPF filter
        if self.filters:
            self.set_filter(self.handler, self.filters)

        self.out_pcap = pcap_dump_open(self.handler, self.out_file) if out_file else NULL

        if self.threaded:
            self.thread = KillableThread(target = self.capture_thread)
            self.thread.start()

    def set_outpcap(self, out_filename):
        """Open a new output pcap file at filename
        """
        self.out_pcap = pcap_dump_open(<pcap_t *>self.handler, os.path.expanduser(self._to_c_str(out_filename)))

    def close_outpcap(self):
        """Close the currently open outpcap file, and flush
        """
        if not self.out_pcap:
            return
        pcap_dump_flush(<pcap_dumper_t *>self.out_pcap)
        pcap_dump_close(<pcap_dumper_t *>self.out_pcap)
        self.out_pcap = NULL

    def get_handler_error(self):
        """handler error
        """

        return self._from_c_str(pcap_geterr(self.handler))

    def is_capturing_threaded(self):
        """Returns if threaded mode is enabled and is currently capturing
        """
        return self.threaded and self.capturing_threaded
    
    def capture_thread(self):
        """The code that runs in the thread when threaded mode is on
        """
        if not self.threaded:
            raise Exception("Not initialized as running in threaded mode")
            return
        
        try:
            while True:
                self.capturing_threaded_requested.wait()
                self.capturing_threaded_requested.clear()
                self.done_capturing.clear()
                self.capturing_threaded = True

                pcap_loop(self.handler, self.count, sniff_callback, <u_char *>self.out_pcap)
                
                self.capturing_threaded = False
                self.done_capturing.set()

        finally:
            pass

    def wait_for_thread(self, timeout=0):
        """Wait for the capture thread to break out of the loop
           This should be called after stop_capture_threaded

           If a timeout is set, block that long then return either way

           Returns-True if the capture is marked as ended, False if the timeout occurred before the capture finished
        """
        if not self.threaded:
            raise Exception("Not initialized as running in threaded mode")
            return True

        if timeout:
            finished=self.done_capturing.wait(timeout)
        else:
            finished=self.done_capturing.wait()
        
        if finished:
            self.done_capturing.clear()
        
        return finished

    
    def run_capture_threaded(self):
        """Directs the capture thread to begin a capture
        """
        if not self.threaded:
            raise Exception("Not initialized as running in threaded mode")
            return
        
        self.capturing_threaded_requested.set()
    
    def stop_capture_threaded(self):
        """Directs the capture thread to break a running capture
        """
        if not self.threaded:
            raise Exception("Not initialized as running in threaded mode")
            return

        self.capturing_threaded_requested.clear()
        
        if self.is_capturing_threaded():
            pcap_breakloop(self.handler)
    
    def capture(self):
        """Run capture packet
        """

        cdef pcap_pkthdr pkt_header

        count = self.count

        while count == -1 or count > 0:
            pkt = <u_char*>pcap_next(self.handler, &pkt_header)
            if pkt == NULL:
                # timeout
                yield 0, 0, b""
            else:
                if self.out_pcap != NULL:
                    pcap_dump(<u_char*>self.out_pcap, &pkt_header, pkt)

                self.capture_cnt += 1
                if count > 0:
                    count -= 1

                yield pkt_header.caplen, pkt_header.ts.tv_sec, (<char*>pkt)[:pkt_header.caplen]

    def stats(self):
        """stats
        """

        cdef pcap_stat ps

        if pcap_stats(self.handler, &ps) != 0:
            raise LibpcapError(self.get_handler_error())

        return StatsObject(self.capture_cnt, ps.ps_recv, ps.ps_drop, ps.ps_ifdrop)

    def close(self):
        """
        close
        """

        self.close_outpcap()

        if self.handler != NULL:
            if self.is_capturing_threaded():
                self.stop_capture_threaded()
                if not self.wait_for_thread(timeout=2):
                    self.thread.raise_exception()

            pcap_close(self.handler)
            self.handler = NULL


cpdef str get_first_iface():
    """Get first iface
    """

    cdef char errbuf[PCAP_ERRBUF_SIZE]
    cdef char* iface

    iface = pcap_lookupdev(errbuf)

    return from_c_str(iface) if iface else ""


cpdef list get_iface_list():
    """Get iface list
    """

    cdef char errbuf[PCAP_ERRBUF_SIZE]
    cdef pcap_if_t *interfaces, *temp
    cdef list iface_list = []

    if pcap_findalldevs(&interfaces, errbuf) == -1:
        return []

    temp = interfaces

    while temp:
        iface_list.append(temp.name.decode("utf-8"))
        temp = temp.next

    pcap_freealldevs(interfaces)

    return iface_list


cpdef bint send_packet(str iface, bytes buf):
    """
    Send raw packet
    """

    cdef char errbuf[PCAP_ERRBUF_SIZE]
    cdef bint status = False

    cdef pcap_t* handler = pcap_open_live(to_c_str(iface), 65535, 0, 0, errbuf)

    if handler == NULL:
        raise from_c_str(errbuf)

    if pcap_sendpacket(handler, buf, len(buf)) != -1:
        status = True

    pcap_close(handler)

    return status


cdef void sniff_callback(u_char *user, const pcap_pkthdr *pkt_header, const u_char *pkt_data):
    """
    """

    if user != NULL:
        pcap_dump(user, pkt_header, pkt_data)
