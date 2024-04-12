import threading
import ctypes

class KillableThread(threading.Thread):
	def __init__(self, *args, **kwargs):
		super(KillableThread, self).__init__(*args, **kwargs)
		
	def get_id(self):
		# returns id of the respective thread
		if hasattr(self, '_thread_id'):
			return self._thread_id
		for id, thread in threading._active.items():
			if thread is self:
				return id

	def raise_exception(self):
		thread_id = self.get_id()
		res = ctypes.pythonapi.PyThreadState_SetAsyncExc(thread_id,
			ctypes.py_object(SystemExit))
		if res > 1:
			ctypes.pythonapi.PyThreadState_SetAsyncExc(thread_id, 0)
			print('Failed to kill thread, exception raise failure')
	